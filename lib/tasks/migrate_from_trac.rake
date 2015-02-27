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
require 'uri'

namespace :redmine do
  desc 'Trac migration script'
  task :migrate_from_trac => :environment do

    module TracMigrate
      class DoubleOut
        def puts(arg)
          STDOUT.puts arg
          STDERR.puts arg
        end
        def print(arg)
          STDOUT.print arg
          STDERR.print arg
        end
      end

      DOUBLEOUT = DoubleOut.new

        TICKET_MAP = []

        DEFAULT_STATUS = IssueStatus.default
        assigned_status = IssueStatus.find_by_position(2)
        resolved_status = IssueStatus.find_by_position(3)
        feedback_status = IssueStatus.find_by_position(4)
        closed_status = IssueStatus.where(:is_closed => true).first
        STATUS_MAPPING = {'new' => DEFAULT_STATUS,
                          'reopened' => feedback_status,
                          'assigned' => assigned_status,
                          'closed' => closed_status
                          }

        priorities = IssuePriority.all
        DEFAULT_PRIORITY = priorities[0]
        PRIORITY_MAPPING = {'lowest' => priorities[0],
                            'low' => priorities[0],
                            'normal' => priorities[1],
                            'high' => priorities[2],
                            'highest' => priorities[3],
                            # ---
                            'trivial' => priorities[0],
                            'minor' => priorities[1],
                            'major' => priorities[2],
                            'critical' => priorities[3],
                            'blocker' => priorities[4]
                            }

        TRACKER_BUG = Tracker.find_by_position(1)
        TRACKER_FEATURE = Tracker.find_by_position(2)
        DEFAULT_TRACKER = TRACKER_BUG
        TRACKER_MAPPING = {'defect' => TRACKER_BUG,
                           'enhancement' => TRACKER_FEATURE,
                           'task' => TRACKER_FEATURE,
                           'patch' =>TRACKER_FEATURE
                           }

        roles = Role.where(:builtin => 0).order('position ASC').all
        manager_role = roles[0]
        developer_role = roles[1]
        DEFAULT_ROLE = roles.last
        ROLE_MAPPING = {'admin' => manager_role,
                        'developer' => developer_role
                        }

        # taken from http://stackoverflow.com/a/16219473
        # The main parse method is mostly borrowed from a tweet by @JEG2
        class StrictTsv
          attr_reader :filepath
          def initialize(filepath)
            @filepath = filepath
          end

          def parse
            open(filepath) do |f|
              f.each do |line|
                fields = line.chomp.split("\t")
                yield fields
              end
            end
          end

          def parse_map
            map = {}
            parse do |row|
              map[row[0]] = row[1]
            end
            map
          end
        end

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
            if TracMigrate.database_version > 22
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

#      private
        def trac_fullpath
          attachment_type = read_attribute(:type)
          trac_file = URI.escape(filename)
          # trac escapes more characters
          trac_file = trac_file.gsub( /[()$\[\]]/ ) do |x|
            codepoint = x.codepoints[0]
            sprintf('%%%02X', codepoint)
          end
          trac_id = read_attribute(:id)
          "#{TracMigrate.trac_attachments_directory}/#{attachment_type}/#{trac_id}/#{trac_file}"
        end
      end

      class TracTicket < ActiveRecord::Base
        self.table_name = :ticket
        set_inheritance_column :none

        # ticket changes: only migrate status changes and comments
        has_many :ticket_changes, :class_name => "TracTicketChange", :foreign_key => :ticket
        has_many :customs, :class_name => "TracTicketCustom", :foreign_key => :ticket

        def attachments
          TracMigrate::TracAttachment.all(:conditions => ["type = 'ticket' AND id = ?", self.id.to_s])
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

      TRAC_WIKI_PAGES = %w(InterMapTxt InterTrac InterWiki RecentChanges SandBox TracAccessibility TracAdmin TracBackup TracBrowser TracCgi TracChangeset \
                           TracEnvironment TracFineGrainedPermissions TracFastCgi TracGuide TracImport TracIni TracInstall TracInterfaceCustomization \
                           TracLinks TracLogging TracModPython TracModWSGI TracNavigation TracNotification TracPermissions TracPlugins TracQuery \
                           TracReports TracRepositoryAdmin TracRevisionLog TracRoadmap TracRss TracSearch TracStandalone TracSupport TracSyntaxColoring TracTickets \
                           TracTicketsCustomFields TracTimeline TracUnicode TracUpgrade TracWiki TracWorkflow WikiDeletePage WikiFormatting \
                           WikiHtml WikiMacros WikiNewPage WikiPageNames WikiProcessors WikiRestructuredText WikiRestructuredTextLinks \
                           CamelCase TitleIndex)

      class TracWikiPage < ActiveRecord::Base
        self.table_name = :wiki
        set_primary_key :name

        def self.columns
          # Hides readonly Trac field to prevent clash with AR readonly? method (Rails 2.0)
          super.select {|column| column.name.to_s != 'readonly'}
        end

        def attachments
          TracMigrate::TracAttachment.all(:conditions => ["type = 'wiki' AND id = ?", self.id.to_s])
        end

        def time; Time.at2(read_attribute(:time)) end
      end

      class TracPermission < ActiveRecord::Base
        self.table_name = :permission
      end

      class TracSessionAttribute < ActiveRecord::Base
        self.table_name = :session_attribute
      end

      def self.find_or_create_user(username, project = nil)
        return User.anonymous if username.blank?

        u = User.find_by_login(username)
        if !u
          # Create a new user if not found
          mail = username[0, User::MAIL_LENGTH_LIMIT]
          if mail_attr = TracSessionAttribute.find_by_sid_and_name(username, 'email')
            mail = mail_attr.value
          end
          mail = "#{mail}@foo.bar" unless mail.include?("@")

          name = username
          if name_attr = TracSessionAttribute.find_by_sid_and_name(username, 'name')
            name = name_attr.value
          end
          name =~ (/(\w+)(\s+\w+)?/)
          fn = ($1 || "-").strip
          ln = ($2 || '-').strip

          u = User.new :mail => mail.gsub(/[^-@a-z0-9\.]/i, '-'),
                       :firstname => fn[0, limit_for(User, 'firstname')],
                       :lastname => ln[0, limit_for(User, 'lastname')]

          u.login = username[0, User::LOGIN_LENGTH_LIMIT].gsub(/[^a-z0-9_\-@\.]/i, '-')
          u.password = @default_password
          u.admin = true if TracPermission.find_by_username_and_action(username, 'admin')
          # finally, a default user is used if the new user is not valid
          u = User.first unless u.save
        end
        # Make sure user is a member of the project
        if project && !u.member_of?(project)
          role = DEFAULT_ROLE
          if u.admin
            role = ROLE_MAPPING['admin']
          elsif TracPermission.find_by_username_and_action(username, 'developer')
            role = ROLE_MAPPING['developer']
          end
          Member.create(:user => u, :project => project, :roles => [role])
          u.reload
        end
        u
      end

      # Basic wiki syntax conversion
      def self.convert_wiki_text(text)
        unless @convert_wiki
          return text
        end
        
        # Titles
        text = text.gsub(/^(\=+)\s(.+)\s(\=+)/) {|s| "\nh#{$1.length}. #{$2}\n"}
        # External Links
        text = text.gsub(/\[(http[^\s]+)\s+([^\]]+)\]/) {|s| "\"#{$2}\":#{$1}"}
        # Ticket links:
        #      [ticket:234 Text],[ticket:234 This is a test]
        text = text.gsub(/\[ticket\:([^\ ]+)\ (.+?)\]/, '"\2":/issues/show/\1')
        #      ticket:1234
        #      #1 is working cause Redmine uses the same syntax.
        text = text.gsub(/ticket\:([^\ ]+)/, '#\1')
        # Milestone links:
        #      [milestone:"0.1.0 Mercury" Milestone 0.1.0 (Mercury)]
        #      The text "Milestone 0.1.0 (Mercury)" is not converted,
        #      cause Redmine's wiki does not support this.
        text = text.gsub(/\[milestone\:\"([^\"]+)\"\ (.+?)\]/, 'version:"\1"')
        #      [milestone:"0.1.0 Mercury"]
        text = text.gsub(/\[milestone\:\"([^\"]+)\"\]/, 'version:"\1"')
        text = text.gsub(/milestone\:\"([^\"]+)\"/, 'version:"\1"')
        #      milestone:0.1.0
        text = text.gsub(/\[milestone\:([^\ ]+)\]/, 'version:\1')
        text = text.gsub(/milestone\:([^\ ]+)/, 'version:\1')
        # Internal Links
        text = text.gsub(/\[\[BR\]\]/, "\n") # This has to go before the rules below
        text = text.gsub(/\[\"(.+)\".*\]/) {|s| "[[#{$1.delete(',./?;|:')}]]"}
        text = text.gsub(/\[wiki:\"(.+)\".*\]/) {|s| "[[#{$1.delete(',./?;|:')}]]"}
        text = text.gsub(/\[wiki:\"(.+)\".*\]/) {|s| "[[#{$1.delete(',./?;|:')}]]"}
        text = text.gsub(/\[wiki:([^\s\]]+)\]/) {|s| "[[#{$1.delete(',./?;|:')}]]"}
        text = text.gsub(/\[wiki:([^\s\]]+)\s(.*)\]/) {|s| "[[#{$1.delete(',./?;|:')}|#{$2.delete(',./?;|:')}]]"}

  # Links to pages UsingJustWikiCaps
  text = text.gsub(/([^!]|^)(^| )([A-Z][a-z]+[A-Z][a-zA-Z]+)/, '\\1\\2[[\3]]')
  # Normalize things that were supposed to not be links
  # like !NotALink
  text = text.gsub(/(^| )!([A-Z][A-Za-z]+)/, '\1\2')
        # Revisions links
        text = text.gsub(/\[(\d+)\]/, 'r\1')
        # Ticket number re-writing
        text = text.gsub(/#(\d+)/) do |s|
          if $1.length < 10
#            TICKET_MAP[$1.to_i] ||= $1
            "\##{TICKET_MAP[$1.to_i] || $1}"
          else
            s
          end
        end
        # We would like to convert the Code highlighting too
        # This will go into the next line.
        shebang_line = false
        # Regular expression for start of code
        pre_re = /\{\{\{/
        # Code highlighting...
        shebang_re = /^\#\!([a-z]+)/
        # Regular expression for end of code
        pre_end_re = /\}\}\}/

        # Go through the whole text..extract it line by line
        text = text.gsub(/^(.*)$/) do |line|
          m_pre = pre_re.match(line)
          if m_pre
            line = '<pre>'
          else
            m_sl = shebang_re.match(line)
            if m_sl
              shebang_line = true
              line = '<code class="' + m_sl[1] + '">'
            end
            m_pre_end = pre_end_re.match(line)
            if m_pre_end
              line = '</pre>'
              if shebang_line
                line = '</code>' + line
              end
            end
          end
          line
        end

        # Highlighting
        text = text.gsub(/'''''([^\s])/, '_*\1')
        text = text.gsub(/([^\s])'''''/, '\1*_')
        text = text.gsub(/'''/, '*')
        text = text.gsub(/''/, '_')
        text = text.gsub(/__/, '+')
        text = text.gsub(/~~/, '-')
        text = text.gsub(/`/, '@')
        text = text.gsub(/,,/, '~')
        # Lists
        text = text.gsub(/^([ ]+)\* /) {|s| '*' * $1.length + " "}

        text
      end

      def self.merge(destination, source)
        source.each do |element|
          destination << element unless destination.include?(element)
        end
      end

      # taken and modified from app/models/attachment.rb
      def self.sanitize_filename(value)
        # get only the filename, not the whole path
        just_filename = value.gsub(/\A.*(\\|\/)/m, '')

        # Finally, replace invalid characters with underscore
        just_filename.gsub(/[\/\?\%\*\:\|\"\'<>\n\r]+/, '_')
      end

      def self.migrate
        establish_connection

        # Quick database test
        TracComponent.count

        lookup_database_version
        print "Trac database version is: ", database_version, "\n"

        migrated_components = 0
        migrated_milestones = 0
        migrated_tickets = 0
        migrated_custom_values = 0
        migrated_ticket_attachments = 0
        migrated_wiki_edits = 0
        migrated_wiki_pages = 0
        migrated_wiki_attachments = 0

        #Wiki system initializing...
        @target_project.wiki.destroy if @target_project.wiki
        @target_project.reload
        wiki = Wiki.new(:project => @target_project, :start_page => 'WikiStart')
        wiki_edit_count = 0

        # Milestones
        DOUBLEOUT.puts "Migrating milestones"
        if !@milestone_map_file.nil?
          milestone_project_map_file = StrictTsv.new(@milestone_map_file) # All target projects must be listed in the map file, even if it involves creating non-existent milestones
          milestone_project_map = milestone_project_map_file.parse_map
        else
          milestone_project_map = {}
        end

        projects = Set.new [@target_project]
        milestone_project_map.each do |milestone_name, project_name|
          project = find_or_create_project(@target_project_prefix + project_name, false)
          projects << project
        end
        
        version_map = {}
        TracMilestone.all.each do |milestone|
          print '.'
          STDOUT.flush
          # First we try to find the wiki page...
          p = wiki.find_or_new_page(milestone.name.to_s)
          p.content = WikiContent.new(:page => p) if p.new_record?
          p.content.text = milestone.description.to_s
          p.content.author = find_or_create_user('trac')
          p.content.comments = 'Milestone'
          p.save

          target_project = @target_project
          target_project_identifier = milestone_project_map[milestone.name.to_s]
          if target_project_identifier
            target_project_identifier = @target_project_prefix + target_project_identifier
            target_project = find_or_create_project(target_project_identifier, false)
          end
          milestone_name = @target_version_prefix + encode(milestone.name[0, limit_for(Version, 'name')])
          v = Version.find(:first, :conditions => ["name = ? and project_id = ?", milestone_name, target_project.id])
          v ||= Version.new :project => target_project,
                          :name => milestone_name,
                          :description => nil,
                          :wiki_page_title => milestone.name.to_s,
                          :effective_date => milestone.completed

          if !v.save
            STDERR.puts "ERROR: Unable to create a version with name '#{milestone_name}'!"
            STDERR.puts "\tversion valid?:#{v.valid?}"
            STDERR.puts "\tversion error:#{v.errors.messages}"
            next
          end
          version_map[milestone.name] = v
          migrated_milestones += 1
        end
        puts

        # Components
        DOUBLEOUT.puts "Migrating components"

        component_project_name_map = {}
        if !@component_project_map_file.blank?
          component_project_name_map_file = StrictTsv.new(@component_project_map_file)
          component_project_name_map = component_project_name_map_file.parse_map
        end

        category_name_map = {}
        if !@component_map_file.blank?
          category_name_map_file = StrictTsv.new(@component_map_file)
          category_name_map = category_name_map_file.parse_map
        end
        
        issues_category_map = {}
        projects.each do |project|
          issues_category_submap = {}
          TracComponent.all.each do |component|
            print '.'
            STDOUT.flush
            component_name = encode(component.name[0, limit_for(IssueCategory, 'name')])
            if !@component_map_file.blank?
              next if category_name_map[component_name].nil?
              category_name = @target_category_prefix + category_name_map[component.name]
              c = IssueCategory.find(:first, :conditions => ["name = ? and project_id = ?", category_name, project.id])
              c ||= IssueCategory.new :project => project,
                                      :name => category_name
            else
              c = IssueCategory.new :project => project,
                                    :name => @target_category_prefix + component_name
            end
            if !c.save
              STDERR.puts "ERROR: Unable to create a category with name '#{category_name}'!"
              STDERR.puts "\tcategory valid?:#{c.valid?}"
              STDERR.puts "\tcategory error:#{c.errors.messages}"
              next
            end
            issues_category_submap[component.name] = c
            migrated_components += 1
          end
          issues_category_map[project] = issues_category_submap
          puts
        end

        # Custom fields
        # TODO: read trac.ini instead
        DOUBLEOUT.puts "Migrating custom fields"
        custom_field_map = {}
        TracTicketCustom.find_by_sql("SELECT DISTINCT name FROM #{TracTicketCustom.table_name}").each do |field|
          print '.'
          STDOUT.flush
          # Redmine custom field name
          # TODO: using limit_for() inside encode() isn't really the proper way to do things.
          field_name = @target_field_name_prefix + encode(field.name[0, limit_for(IssueCustomField, 'name') - @target_field_name_prefix.length])
          # Find if the custom already exists in Redmine
          f = IssueCustomField.find_by_name(field_name)
          # Or create a new one
          f ||= IssueCustomField.create(:name => field_name,
                                        :field_format => 'string')

          next if f.new_record?
          f.trackers = Tracker.all
          merge(f.projects, projects)
          custom_field_map[field.name] = f
        end
        puts

        # Trac 'resolution' field as a Redmine custom field
        if @target_field_name_prefix_resolution
          target_resolution_field_name = @target_field_name_prefix + "resolution"
        else
          target_resolution_field_name = "Resolution"
        end
        r = IssueCustomField.where(:name => target_resolution_field_name).first
        r = IssueCustomField.new(:name => target_resolution_field_name,
                                 :field_format => 'list',
                                 :is_filter => true) if r.nil?
        r.trackers = Tracker.all
        merge(r.projects, projects)
        r.possible_values = (r.possible_values + %w(fixed invalid wontfix duplicate worksforme)).flatten.compact.uniq
        r.save!
        custom_field_map['resolution'] = r

        # Trac ID field as a Redmine custom field
        if !@target_trac_id_field_name.blank?
          trac_id_field = IssueCustomField.find_by_name(@target_trac_id_field_name)
          trac_id_field ||= IssueCustomField.create(:name => @target_trac_id_field_name,
                                                    :field_format => 'int')
          if !trac_id_field.new_record?
            trac_id_field.trackers = Tracker.all
            merge(trac_id_field.projects, projects)
          end

          custom_field_map['id'] = trac_id_field
        end

        # Trac component field as a Redmine custom field
        target_component_field_name = @target_field_name_prefix + "component"
        trac_component_field = IssueCustomField.find_by_name(target_component_field_name)
        trac_component_field ||= IssueCustomField.create(:name => target_component_field_name,
                                                         :field_format => 'string')
        if !trac_component_field.new_record?
          trac_component_field.trackers = Tracker.all
          merge(trac_component_field.projects, projects)
        end
          
        custom_field_map['component'] = trac_component_field

#puts "saving time"
#if false
        # Tickets
        DOUBLEOUT.puts "Migrating tickets"
        TracTicket.find_each(:batch_size => 200) do |ticket|
          print '.'
          STDOUT.flush

          fixed_version = version_map[ticket.milestone]
          if fixed_version.nil?
            if component_project_name_map[ticket.component].nil?
              target_project = @target_project
            else
              project_name = @target_project_prefix + component_project_name_map[ticket.component]
              target_project = find_or_create_project(project_name, false)
            end
          elsif 
            target_project = fixed_version.project
          end
          
          i = Issue.new :project => target_project,
                        :subject => encode(ticket.summary[0, limit_for(Issue, 'subject')]),
                        :description => convert_wiki_text(encode(ticket.description)),
                        :priority => PRIORITY_MAPPING[ticket.priority] || DEFAULT_PRIORITY,
                        :created_on => ticket.time,
                        :updated_on => ticket.changetime
          i.author = find_or_create_user(ticket.reporter)
if issues_category_map[target_project].nil?
  raise "#{target_project} was not found in issues category map"
end
          i.category = issues_category_map[target_project][ticket.component] unless ticket.component.blank?
          i.fixed_version = fixed_version
          i.status = STATUS_MAPPING[ticket.status] || DEFAULT_STATUS
          i.tracker = TRACKER_MAPPING[ticket.ticket_type] || DEFAULT_TRACKER
#         i.id = ticket.id unless Issue.exists?(ticket.id) # disabled because there may be a problem with Redmine if we do this.
          next unless Time.fake(ticket.changetime) { i.save }
          TICKET_MAP[ticket.id] = i.id
          migrated_tickets += 1

          # Owner
          unless ticket.owner.blank?
            i.assigned_to = find_or_create_user(ticket.owner, target_project)
            Time.fake(ticket.changetime) { i.save }
          end

          # Comments and status/resolution changes
          ticket.ticket_changes.group_by(&:time).each do |time, changeset|
            status_change = changeset.select {|change| change.field == 'status'}.first
            resolution_change = changeset.select {|change| change.field == 'resolution'}.first
            comment_change = changeset.select {|change| change.field == 'comment'}.first

            n = Journal.new :notes => (comment_change ? convert_wiki_text(encode(comment_change.newvalue)) : ''),
                            :created_on => time
            n.user = find_or_create_user(changeset.first.author)
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
            if !attachment.exist?
              STDERR.puts "ERROR: doesn't exist:" + attachment.filename + ':' + attachment.trac_fullpath
              next
            end
            STDERR.puts "#{i.id}+#{attachment.filename}"
            attachment.open {
              a = Attachment.new :created_on => attachment.time
              a.file = attachment
              a.author = find_or_create_user(attachment.author)
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
          if !@target_trac_id_field_name.blank?
            custom_values[custom_field_map['id'].id] = ticket.id
          end
          custom_values[custom_field_map['component'].id] = ticket.component
            
          i.custom_field_values = custom_values
          i.save_custom_field_values
        end
#end

        # update issue id sequence if needed (postgresql)
        Issue.connection.reset_pk_sequence!(Issue.table_name) if Issue.connection.respond_to?('reset_pk_sequence!')
        puts

        # Wiki
        DOUBLEOUT.puts "Migrating wiki"
        if wiki.save
          page_history = {}
          page_set = Set.new
          TracWikiPage.order('name, version').all.each do |page|
            # Do not migrate Trac manual wiki pages
            next if TRAC_WIKI_PAGES.include?(page.name)
            wiki_edit_count += 1
            print '.'
            DOUBLEOUT.puts page.name
            STDOUT.flush
            page_set << page.name
            titleized_name = Wiki.titleize(page.name)
            name_in_history = page_history[titleized_name]
            if name_in_history.nil?
              page_history[titleized_name] = page.name
            elsif name_in_history != page.name
              STDERR.puts "ERROR: page name collision #{page.name}->#{titleized_name}<-#{name_in_history}"
            end
            p = wiki.find_or_new_page(page.name)
            p.content = WikiContent.new(:page => p) if p.new_record?
            p.content.text = page.text
            p.content.author = find_or_create_user(page.author) unless page.author.blank? || page.author == 'trac'
            p.content.comments = page.comment
            Time.fake(page.time) do
              if p.new_record?
                migrated_wiki_pages += 1
                p.save
              else
                print '^'
                p.content.save
              end
            end

            next if p.content.new_record?
            migrated_wiki_edits += 1

            # Attachments
            attachment_history = {}
            page.attachments.each do |attachment|
              if !attachment.exist?
                raise " doesn't exist:" + attachment.filename + ':' + attachment.trac_fullpath
                next
              end
              sanitized_filename = sanitize_filename(attachment.filename)
              attachment_in_history = attachment_history[sanitized_filename]
              if attachment_in_history
                STDERR.puts "ERROR: filename collision: #{attachment.filename}->#{sanitized_filename}<-#{attachment_in_history}"
              end
              if p.attachments.find_by_filename(sanitized_filename) #add only once per page
                print ">"
                STDERR.puts "#{p.title}>#{attachment.filename}"
                next
              end
              STDERR.puts "#{p.title}+#{attachment.filename}"
              attachment.open {
                a = Attachment.new :created_on => attachment.time
                a.file = attachment
                a.author = find_or_create_user(attachment.author)
                a.description = attachment.description
                a.container = p
                if !a.save
                  STDERR.puts "ERROR: Unable to create an attachment with file name '#{attachment.filename}'!"
                  STDERR.puts "\tvalid?:#{a.valid?}"
                  STDERR.puts "\terror:#{a.errors.messages}"
                else
                  migrated_wiki_attachments += 1
                end
              }
            end
          end

          wiki.reload
          wiki.pages.each do |page|
            page.content.text = convert_wiki_text(page.content.text)
            Time.fake(page.content.updated_on) { page.content.save }
          end
        end
        puts

        puts
        DOUBLEOUT.puts "Components:      #{migrated_components}/#{TracComponent.count}"
        DOUBLEOUT.puts "Milestones:      #{migrated_milestones}/#{TracMilestone.count}"
        DOUBLEOUT.puts "Tickets:         #{migrated_tickets}/#{TracTicket.count}"
        DOUBLEOUT.puts "Ticket files:    #{migrated_ticket_attachments}/" + TracAttachment.count(:conditions => {:type => 'ticket'}).to_s
        DOUBLEOUT.puts "Custom values:   #{migrated_custom_values}/#{TracTicketCustom.count}"
        DOUBLEOUT.puts "Wiki pages:      #{migrated_wiki_pages}/" + page_set.size.to_s
        DOUBLEOUT.puts "Wiki edits:      #{migrated_wiki_edits}/#{wiki_edit_count}"
        DOUBLEOUT.puts "Wiki files:      #{migrated_wiki_attachments}/" + TracAttachment.count(:conditions => {:type => 'wiki'}).to_s
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
        STDERR.puts "ERROR: " + e.to_s
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
        STDERR.puts "ERROR: " + e.to_s
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

      def self.set_target_trac_id_field_name(trac_id_field_name)
        @target_trac_id_field_name = trac_id_field_name
      end

      def self.set_target_field_name_prefix(prefix)
        @target_field_name_prefix = prefix
      end

      def self.set_prefix_resolution(prefix_resolution)
        @target_field_name_prefix_resolution = prefix_resolution
      end

      def self.set_component_map_file(map_file)
        @component_map_file = map_file
      end

      def self.set_target_category_prefix(category_prefix)
        @target_category_prefix = category_prefix
      end

      def self.set_milestone_map_file(map_file)
        @milestone_map_file = map_file
      end

      def self.set_component_project_map_file(map_file)
        @component_project_map_file = map_file
      end

      def self.set_convert_wiki(convert_wiki)
        @convert_wiki = convert_wiki
      end

      def self.set_target_project_prefix(project_prefix)
        @target_project_prefix = project_prefix
      end

      def self.set_humanize_project(humanize_project)
        @humanize_project = humanize_project
      end

      def self.set_target_version_prefix(version_prefix)
        @target_version_prefix = version_prefix
      end

      def self.set_default_password(password)
        @default_password = password
      end

      def self.find_or_create_project(identifier, warning)
        project = Project.find_by_identifier(identifier)
        if !project
          # create the target project
          project = Project.new :name => @humanize_project ? identifier.humanize : identifier,
                                :description => ''
          project.identifier = identifier
          if !project.save
            STDERR.puts "ERROR: Unable to create a project with identifier '#{identifier}'!"
            STDERR.puts "\tproject valid?:#{project.valid?}"
            STDERR.puts "\tproject error:#{project.errors.messages}"
          end
          # enable issues and wiki for the created project
          project.enabled_module_names = ['issue_tracking', 'wiki']
        elsif warning
          puts
          puts "This project already exists in your Redmine database."
          print "Are you sure you want to append data to this project ? [Y/n] "
          STDOUT.flush
          exit if STDIN.gets.match(/^n$/i)
        end
        project.trackers << TRACKER_BUG unless project.trackers.include?(TRACKER_BUG)
        project.trackers << TRACKER_FEATURE unless project.trackers.include?(TRACKER_FEATURE)
        project
      end

      def self.target_project_identifier(identifier)
        project = find_or_create_project(identifier, true)
        @target_project = project.new_record? ? nil : project
        @target_project.reload
      end

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
      STDERR.puts "ERROR: Redmine configuration need to be loaded before importing data."
      STDERR.puts "Please, run this first:"
      STDERR.puts
      STDERR.puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
      exit
    end

    puts "WARNING: New project(s) will be added to Redmine during this process."
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

    def promptBoolean(text, options = {}, &block)
      default = options[:default]
      while true
        print "#{text} [" + (default.nil? ? "y/n" : (default ? "Y/n" : "y/N")) + "]: "
        STDOUT.flush
        value = STDIN.gets.chomp!
        if (!default.nil? && value.blank?)
          yield default
        elsif value.match(/^y$/i)
          yield true
        elsif value.match(/^n$/i)
          yield false
        else
          puts "Enter y or n!"
          next
        end
        break
      end
    end

    DEFAULT_PORTS = {'mysql' => 3306, 'postgresql' => 5432}

    prompt('Trac directory') {|directory| TracMigrate.set_trac_directory directory.strip}
    prompt('Trac database adapter (sqlite3, mysql2, postgresql)', :default => 'sqlite3') {|adapter| TracMigrate.set_trac_adapter adapter}
    unless %w(sqlite3).include?(TracMigrate.trac_adapter)
      prompt('Trac database host', :default => 'localhost') {|host| TracMigrate.set_trac_db_host host}
      prompt('Trac database port', :default => DEFAULT_PORTS[TracMigrate.trac_adapter]) {|port| TracMigrate.set_trac_db_port port}
      prompt('Trac database name') {|name| TracMigrate.set_trac_db_name name}
      prompt('Trac database schema', :default => 'public') {|schema| TracMigrate.set_trac_db_schema schema}
      prompt('Trac database username') {|username| TracMigrate.set_trac_db_username username}
      prompt('Trac database password') {|password| TracMigrate.set_trac_db_password password}
    end
    prompt('Trac database encoding', :default => 'UTF-8') {|encoding| TracMigrate.encoding encoding}
    prompt('Trac component>Redmine category map file (tab-delimited)', :default => nil) {|map_file| TracMigrate.set_component_map_file map_file}
    prompt('Trac milestone>Redmine project map file (tab-delimited)', :default => nil) {|map_file| TracMigrate.set_milestone_map_file map_file}
    prompt('Trac component>Redmine project map file (tab-delimited)', :default => nil) {|map_file| TracMigrate.set_component_project_map_file map_file}
    promptBoolean('Try to convert wiki format?', :default => true) {|convert| TracMigrate.set_convert_wiki convert}
    puts 'For project identifiers: Only lower case letters (a-z), numbers, dashes and underscores are allowed, must start with a lower case letter.'
    target_project_identifer = ''
    prompt('Target project identifier (not prefixed)') do |identifier|
      target_project_identifer = identifier
      TracMigrate.target_project_identifier identifier
    end
    defaultPrefix = target_project_identifer + '_'
    prompt('Target field name prefix', :default => defaultPrefix) do |prefix|
      defaultPrefix = prefix
      TracMigrate.set_target_field_name_prefix prefix
    end
    promptBoolean("Add prefix to resolution?", :default => true) {|prefix_resolution| TracMigrate.set_prefix_resolution prefix_resolution}
    defaultPrefix2 = ''
    prompt('Target field name for Trac ID (not prefixed)', :default => defaultPrefix + "id") {|target_trac_id_field_name| TracMigrate.set_target_trac_id_field_name target_trac_id_field_name}
    prompt('Redmine category prefix', :default => defaultPrefix2) {|target_category_prefix| TracMigrate.set_target_category_prefix target_category_prefix}
    prompt('Redmine project prefix', :default => defaultPrefix2) {|target_project_prefix| TracMigrate.set_target_project_prefix target_project_prefix}
    promptBoolean('Humanize Redmine project?', :default => true) {|humanize_project| TracMigrate.set_humanize_project humanize_project}
    prompt('Redmine version prefix', :default => defaultPrefix2) {|target_version_prefix| TracMigrate.set_target_version_prefix target_version_prefix}
    prompt('Default password for users', :default => '') {|password| TracMigrate.set_default_password password}
                                                                                                                                       
    puts

    old_notified_events = Setting.notified_events
    old_password_min_length = Setting.password_min_length
    begin
      # Turn off email notifications temporarily
      Setting.notified_events = []
      Setting.password_min_length = 4
      # Run the migration
      TracMigrate.migrate
    ensure
      # Restore previous settings
      Setting.notified_events = old_notified_events
      Setting.password_min_length = old_password_min_length
    end
  end
end
