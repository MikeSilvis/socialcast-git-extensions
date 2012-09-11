require "thor"
require 'rest_client'
require 'socialcast-git-extensions'

module Socialcast
  module Gitx
    class CLI < Thor
      include Socialcast::Gitx
      include Socialcast::Gitx::Git
      include Socialcast::Gitx::Github

      PULL_REQUEST_DESCRIPTION = "\n\n" + <<-EOS.dedent
        # Describe your pull request
        # Use GitHub flavored Markdown http://github.github.com/github-flavored-markdown/
        # Why not include a screenshot? Format is ![title](url)
      EOS

      method_option :quiet, :type => :boolean, :aliases => '-q'
      method_option :trace, :type => :boolean, :aliases => '-v'
      def initialize(*args)
        super(*args)
        RestClient.proxy = ENV['HTTPS_PROXY'] if ENV.has_key?('HTTPS_PROXY')
        RestClient.log = Logger.new(STDOUT) if options[:trace]
      end

      desc "reviewrequest", "Create a pull request on github"
      method_option :description, :type => :string, :aliases => '-d', :desc => 'pull request description'
      # @see http://developer.github.com/v3/pulls/
      def reviewrequest
        token = authorization_token

        update

        description = options[:description] || editor_input(PULL_REQUEST_DESCRIPTION)
        branch = current_branch
        repo = current_repo
        url = create_pull_request token, branch, repo, description

        short_description = description.split("\n").first(5).join("\n")
        review_message = ["@SocialcastDevelopers #reviewrequest for #{branch} #scgitx", short_description, changelog_summary(branch)].join("\n\n")
        post review_message, :url => url, :message_type => 'review_request'
      end

      desc 'update', 'Update the current branch with latest changes from the remote feature branch and master'
      def update
        branch = current_branch

        say 'updating '
        say "#{branch} ", :green
        say "to have most recent changes from "
        say Socialcast::Gitx::BASE_BRANCH, :green

        run_cmd "git pull origin #{branch}" rescue nil
        run_cmd "git pull origin #{Socialcast::Gitx::BASE_BRANCH}"
        run_cmd 'git push origin HEAD'
      end

      desc 'cleanup', 'Cleanup branches that have been merged into master from the repo'
      def cleanup
        run_cmd "git checkout #{Socialcast::Gitx::BASE_BRANCH}"
        run_cmd "git pull"
        run_cmd 'git remote prune origin'

        say "Deleting branches that have been merged into "
        say Socialcast::Gitx::BASE_BRANCH, :green
        branches(:merged => true, :remote => true).each do |branch|
          run_cmd "grb rm #{branch}" unless aggregate_branch?(branch)
        end
        branches(:merged => true).each do |branch|
          run_cmd "git branch -d #{branch}" unless aggregate_branch?(branch)
        end
      end

      desc 'track', 'set the current branch to track the remote branch with the same name'
      def track
        branch = current_branch
        run_cmd "git branch --set-upstream #{branch} origin/#{branch}"
      end

      desc 'start', 'start a new git branch with latest changes from master'
      def start(branch_name = nil)
        unless branch_name
          example_branch = %w{ api-fix-invalid-auth desktop-cleanup-avatar-markup share-form-add-edit-link }.sort_by { rand }.first
          repo = Grit::Repo.new(Dir.pwd)
          remote_branches = repo.remotes.collect {|b| b.name.split('/').last }
          until branch_name = ask("What would you like to name your branch? (ex: #{example_branch})") {|q|
              q.validate = Proc.new { |branch|
                branch =~ /^[A-Za-z0-9\-_]+$/ && !remote_branches.include?(branch)
              }
            }
          end
        end

        run_cmd "git checkout #{Socialcast::Gitx::BASE_BRANCH}"
        run_cmd 'git pull'
        run_cmd "git checkout -b #{branch_name}"

        post "#worklog starting work on #{branch_name} #scgitx"
      end

      desc 'share', 'Share the current branch in the remote repository'
      def share
        run_cmd "grb publish #{current_branch}"
      end

      desc 'integrate', 'integrate the current branch into one of the aggregate development branches'
      def integrate(target_branch = 'prototype')
        branch = current_branch

        update
        integrate_branch(branch, target_branch)
        integrate_branch(target_branch, 'prototype') if target_branch == 'staging'
        run_cmd "git checkout #{branch}"

        post "#worklog integrating #{branch} into #{target_branch} #scgitx"
      end

      desc 'promote', '(DEPRECATED) promote the current branch into staging'
      def promote
        say 'DEPRECATED: Use `git integrate staging` instead', :red
        integrate 'staging'
      end

      desc 'nuke', 'nuke the specified aggregate branch and reset it to a known good state'
      method_option :destination, :type => :string, :aliases => '-d', :desc => 'destination branch to reset to'
      def nuke(bad_branch)
        default_good_branch = "last_known_good_#{bad_branch}"
        good_branch = options[:destination] || ask("What branch do you want to reset #{bad_branch} to? (default: #{default_good_branch})")
        good_branch = default_good_branch if good_branch.length == 0
        good_branch = "last_known_good_#{good_branch}" unless good_branch.starts_with?('last_known_good_')

        removed_branches = reset_branch(bad_branch, good_branch)
        reset_branch("last_known_good_#{bad_branch}", good_branch)

        message_parts = []
        message_parts << "#worklog resetting #{bad_branch} branch to #{good_branch} #scgitx"
        if removed_branches.any?
          message_parts << ""
          message_parts << "the following branches were affected:"
          message_parts += removed_branches.map{|b| ['*', b].join(' ')}
        end
        post message_parts.join("\n")
      end

      desc 'release', 'release the current branch to production'
      def release
        branch = current_branch
        assert_not_protected_branch!(branch, 'release')

        return unless yes?("Release #{branch} to production? (y/n)", :green)

        say "
        You should retain #{branch} for backporting if

          \t* It aims to fix some kind of problem with functionality already released to SaaS

          \t* You have been instructed to retain this branch

          \t* You're not sure (better safe than sorry!)

          ".gsub(/^[ ]+/, "")

        retain_branch branch if yes?("Retain a copy of #{branch} for backporting? (y/n)", :green) 

        update
        run_cmd "git checkout #{Socialcast::Gitx::BASE_BRANCH}"
        run_cmd "git pull origin #{Socialcast::Gitx::BASE_BRANCH}"
        run_cmd "git pull . #{branch}"
        run_cmd "git push origin HEAD"
        integrate_branch('master', 'staging')
        cleanup

        post "#worklog releasing #{branch} to production #scgitx"
      end

      private

      # post a message in socialcast
      # skip sharing message if CLI quiet option is present
      def post(message, params = {})
        return if options[:quiet]
        require 'socialcast'
        require 'socialcast/message'
        ActiveResource::Base.logger = Logger.new(STDOUT) if options[:trace]
        Socialcast::Message.configure_from_credentials
        Socialcast::Message.create params.merge(:body => message)
        say "Message has been posted"
      end
    end
  end
end
