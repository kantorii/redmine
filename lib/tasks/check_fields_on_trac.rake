# Redmine - project management software
# Copyright (C) 2006-2015  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'active_record'
require 'iconv' if RUBY_VERSION < '1.9'
require 'pp'

namespace :redmine do
  desc 'Script to check values of fields on Trac'
  task :check_fields_on_trac => :environment do

    module TracFieldCheck
        TICKET_MAP = []

      class ::Time
        class << self
          alias :real_now :now
          def now
            real_now - @fake_diff.to_i
          end

          def fake(time)
            @fake_diff = real_now - time
            res = yield
            @fake_diff = 0
           res
          end

          def at2(time)
            # modified from http://www.redmine.org/issues/14567#note-12
            if TracFieldCheck.database_version > 22
              Time.at(0, time)
            else
              Time.at(time)
            end
          end
        end
      end

      class TracSystem < ActiveRecord::Base
        self.table_name = :system
      end

      class TracComponent < ActiveRecord::Base
        self.table_name = :component
      end

      class TracMilestone < ActiveRecord::Base
        self.table_name = :milestone
        # If this attribute is set a milestone has a defined target timepoint
        def due
          if read_attribute(:due) && read_attribute(:due) > 0
            Time.at2(read_attribute(:due)).to_date
          else
            nil
          end
        end
        # This is the real timepoint at which the milestone has finished.
        def completed
          if read_attribute(:completed) && read_attribute(:completed) > 0
            Time.at2(read_attribute(:completed)).to_date
          else
            nil
          end
        end

        def description
          # Attribute is named descr in Trac v0.8.x
          has_attribute?(:descr) ? read_attribute(:descr) : read_attribute(:description)
        end
      end

      class TracTicketCustom < ActiveRecord::Base
        self.table_name = :ticket_custom
      end

      class TracAttachment < ActiveRecord::Base
        self.table_name = :attachment
        set_inheritance_column :none

        def time; Time.at2(read_attribute(:time)) end

        def original_filename
          filename
        end

        def content_type
          ''
        end

        def exist?
          File.file? trac_fullpath
        end

        def open
          File.open("#{trac_fullpath}", 'rb') {|f|
            @file = f
            yield self
          }
        end

        def read(*args)
          @file.read(*args)
        end

        def description
          read_attribute(:description).to_s.slice(0,255)
        end

      private
        def trac_fullpath
          attachment_type = read_attribute(:type)
          #replace exotic characters with their hex representation to avoid invalid filenames
          trac_file = filename.gsub( /[^a-zA-Z0-9\-_\.!~*']/n ) do |x|
            codepoint = RUBY_VERSION < '1.9' ? x[0] : x.codepoints.to_a[0]
            sprintf('%%%02x', codepoint)
          end
          "#{TracFieldCheck.trac_attachments_directory}/#{attachment_type}/#{id}/#{trac_file}"
        end
      end

      class TracTicket < ActiveRecord::Base
        self.table_name = :ticket
        set_inheritance_column :none

        # ticket changes: only migrate status changes and comments
        has_many :ticket_changes, :class_name => "TracTicketChange", :foreign_key => :ticket
        has_many :customs, :class_name => "TracTicketCustom", :foreign_key => :ticket

        def attachments
          TracFieldCheck::TracAttachment.all(:conditions => ["type = 'ticket' AND id = ?", self.id.to_s])
        end

        def ticket_type
          read_attribute(:type)
        end

        def summary
          read_attribute(:summary).blank? ? "(no subject)" : read_attribute(:summary)
        end

        def description
          read_attribute(:description).blank? ? summary : read_attribute(:description)
        end

        def time; Time.at2(read_attribute(:time)) end
        def changetime; Time.at2(read_attribute(:changetime)) end
      end

      class TracTicketChange < ActiveRecord::Base
        self.table_name = :ticket_change

        def self.columns
          # Hides Trac field 'field' to prevent clash with AR field_changed? method (Rails 3.0)
          super.select {|column| column.name.to_s != 'field'}
        end

        def time; Time.at2(read_attribute(:time)) end
      end

      class TracPermission < ActiveRecord::Base
        self.table_name = :permission
      end

      class TracSessionAttribute < ActiveRecord::Base
        self.table_name = :session_attribute
      end

      def self.find_user(username, project_member = false)
        return User.anonymous if username.blank?

        u = User.find_by_login(username)
        u
      end

      def self.do_check
        establish_connection

        # Quick database test
        TracComponent.count

        lookup_database_version
        print "Trac database version is: ", database_version, "\n"

        # Components
        print "===Checking components===\n"
        TracComponent.all.each do |component|
          puts encode(component.name)
        end
        puts

        # Milestones
        print "===Checking milestones===\n"
        TracMilestone.all.each do |milestone|
          puts encode(milestone.name)
        end
        puts

        # Custom fields
        # TODO: read trac.ini instead
        print "===Checking custom fields===\n"
        TracTicketCustom.find_by_sql("SELECT DISTINCT name FROM #{TracTicketCustom.table_name}").each do |field|
          puts encode(field.name)
        end
        puts

        if false
          # Trac 'resolution' field as a Redmine custom field
          r = IssueCustomField.where(:name => "Resolution").first
          r = IssueCustomField.new(:name => 'Resolution',
                                   :field_format => 'list',
                                   :is_filter => true) if r.nil?
          r.trackers = Tracker.all
          r.projects << @target_project
          r.possible_values = (r.possible_values + %w(fixed invalid wontfix duplicate worksforme)).flatten.compact.uniq
          r.save!
          custom_field_map['resolution'] = r
        end

        if false
          # Tickets
          print "Migrating tickets"
          TracTicket.find_each(:batch_size => 200) do |ticket|
            print '.'
            STDOUT.flush
            i = Issue.new :project => @target_project,
                          :subject => encode(ticket.summary[0, limit_for(Issue, 'subject')]),
                          :description => convert_wiki_text(encode(ticket.description)),
                          :priority => PRIORITY_MAPPING[ticket.priority] || DEFAULT_PRIORITY,
                          :created_on => ticket.time,
                          :updated_on => ticket.changetime
            i.author = find_user(ticket.reporter)
            i.category = issues_category_map[ticket.component] unless ticket.component.blank?
            i.fixed_version = version_map[ticket.milestone] unless ticket.milestone.blank?
            i.status = STATUS_MAPPING[ticket.status] || DEFAULT_STATUS
            i.tracker = TRACKER_MAPPING[ticket.ticket_type] || DEFAULT_TRACKER
            i.id = ticket.id unless Issue.exists?(ticket.id)
            next unless Time.fake(ticket.changetime) { i.save }
            TICKET_MAP[ticket.id] = i.id
            migrated_tickets += 1

            # Owner
            unless ticket.owner.blank?
              i.assigned_to = find_user(ticket.owner, true)
              Time.fake(ticket.changetime) { i.save }
            end

            # Comments and status/resolution changes
            ticket.ticket_changes.group_by(&:time).each do |time, changeset|
              status_change = changeset.select {|change| change.field == 'status'}.first
              resolution_change = changeset.select {|change| change.field == 'resolution'}.first
              comment_change = changeset.select {|change| change.field == 'comment'}.first

              n = Journal.new :notes => (comment_change ? convert_wiki_text(encode(comment_change.newvalue)) : ''),
                              :created_on => time
              n.user = find_user(changeset.first.author)
              n.journalized = i
              if status_change &&
                 STATUS_MAPPING[status_change.oldvalue] &&
                 STATUS_MAPPING[status_change.newvalue] &&
                 (STATUS_MAPPING[status_change.oldvalue] != STATUS_MAPPING[status_change.newvalue])
                n.details << JournalDetail.new(:property => 'attr',
                                               :prop_key => 'status_id',
                                               :old_value => STATUS_MAPPING[status_change.oldvalue].id,
                                               :value => STATUS_MAPPING[status_change.newvalue].id)
              end
              if resolution_change
                n.details << JournalDetail.new(:property => 'cf',
                                               :prop_key => custom_field_map['resolution'].id,
                                               :old_value => resolution_change.oldvalue,
                                               :value => resolution_change.newvalue)
              end
              n.save unless n.details.empty? && n.notes.blank?
            end

            # Attachments
            ticket.attachments.each do |attachment|
              next unless attachment.exist?
              attachment.open {
                a = Attachment.new :created_on => attachment.time
                a.file = attachment
                a.author = find_user(attachment.author)
                a.container = i
                a.description = attachment.description
                migrated_ticket_attachments += 1 if a.save
              }
            end

            # Custom fields
            custom_values = ticket.customs.inject({}) do |h, custom|
              if custom_field = custom_field_map[custom.name]
                h[custom_field.id] = custom.value
                migrated_custom_values += 1
              end
              h
            end
            if custom_field_map['resolution'] && !ticket.resolution.blank?
              custom_values[custom_field_map['resolution'].id] = ticket.resolution
            end
            i.custom_field_values = custom_values
            i.save_custom_field_values
          end
          

          # update issue id sequence if needed (postgresql)
          Issue.connection.reset_pk_sequence!(Issue.table_name) if Issue.connection.respond_to?('reset_pk_sequence!')
          puts
        end

        puts
      end

      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end

      def self.encoding(charset)
        @charset = charset
      end

      def self.lookup_database_version
        f = TracSystem.find_by_name("database_version")
        @@database_version = f.value.to_i
      end

      def self.database_version
        @@database_version
      end

      def self.set_trac_directory(path)
        @@trac_directory = path
        raise "This directory doesn't exist!" unless File.directory?(path)
        raise "#{trac_attachments_directory} doesn't exist!" unless File.directory?(trac_attachments_directory)
        @@trac_directory
      rescue Exception => e
        puts e
        return false
      end

      def self.trac_directory
        @@trac_directory
      end

      def self.set_trac_adapter(adapter)
        return false if adapter.blank?
        raise "Unknown adapter: #{adapter}!" unless %w(sqlite3 mysql postgresql).include?(adapter)
        # If adapter is sqlite or sqlite3, make sure that trac.db exists
        raise "#{trac_db_path} doesn't exist!" if %w(sqlite3).include?(adapter) && !File.exist?(trac_db_path)
        @@trac_adapter = adapter
      rescue Exception => e
        puts e
        return false
      end

      def self.set_trac_db_host(host)
        return nil if host.blank?
        @@trac_db_host = host
      end

      def self.set_trac_db_port(port)
        return nil if port.to_i == 0
        @@trac_db_port = port.to_i
      end

      def self.set_trac_db_name(name)
        return nil if name.blank?
        @@trac_db_name = name
      end

      def self.set_trac_db_username(username)
        @@trac_db_username = username
      end

      def self.set_trac_db_password(password)
        @@trac_db_password = password
      end

      def self.set_trac_db_schema(schema)
        @@trac_db_schema = schema
      end

      mattr_reader :trac_directory, :trac_adapter, :trac_db_host, :trac_db_port, :trac_db_name, :trac_db_schema, :trac_db_username, :trac_db_password

      def self.trac_db_path; "#{trac_directory}/db/trac.db" end
      def self.trac_attachments_directory; "#{trac_directory}/attachments" end

      def self.connection_params
        if trac_adapter == 'sqlite3'
          {:adapter => 'sqlite3',
           :database => trac_db_path}
        else
          {:adapter => trac_adapter,
           :database => trac_db_name,
           :host => trac_db_host,
           :port => trac_db_port,
           :username => trac_db_username,
           :password => trac_db_password,
           :schema_search_path => trac_db_schema
          }
        end
      end

      def self.establish_connection
        constants.each do |const|
          klass = const_get(const)
          next unless klass.respond_to? 'establish_connection'
          klass.establish_connection connection_params
        end
      end

      def self.encode(text)
        if RUBY_VERSION < '1.9'
          @ic ||= Iconv.new('UTF-8', @charset)
          @ic.iconv text
        else
          text.to_s.force_encoding(@charset).encode('UTF-8')
        end
      end
    end

    puts
    if Redmine::DefaultData::Loader.no_data?
      puts "Redmine configuration need to be loaded before importing data."
      puts "Please, run this first:"
      puts
      puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
      exit
    end

    puts "WARNING: a new project will be added to Redmine during this process."
    print "Are you sure you want to continue ? [y/N] "
    STDOUT.flush
    break unless STDIN.gets.match(/^y$/i)
    puts

    def prompt(text, options = {}, &block)
      default = options[:default] || ''
      while true
        print "#{text} [#{default}]: "
        STDOUT.flush
        value = STDIN.gets.chomp!
        value = default if value.blank?
        break if yield value
      end
    end

    DEFAULT_PORTS = {'mysql' => 3306, 'postgresql' => 5432}

    prompt('Trac directory') {|directory| TracFieldCheck.set_trac_directory directory.strip}
    prompt('Trac database adapter (sqlite3, mysql2, postgresql)', :default => 'sqlite3') {|adapter| TracFieldCheck.set_trac_adapter adapter}
    unless %w(sqlite3).include?(TracFieldCheck.trac_adapter)
      prompt('Trac database host', :default => 'localhost') {|host| TracFieldCheck.set_trac_db_host host}
      prompt('Trac database port', :default => DEFAULT_PORTS[TracFieldCheck.trac_adapter]) {|port| TracFieldCheck.set_trac_db_port port}
      prompt('Trac database name') {|name| TracFieldCheck.set_trac_db_name name}
      prompt('Trac database schema', :default => 'public') {|schema| TracFieldCheck.set_trac_db_schema schema}
      prompt('Trac database username') {|username| TracFieldCheck.set_trac_db_username username}
      prompt('Trac database password') {|password| TracFieldCheck.set_trac_db_password password}
    end
    prompt('Trac database encoding', :default => 'UTF-8') {|encoding| TracFieldCheck.encoding encoding}
    puts

    TracFieldCheck.do_check
  end
end
