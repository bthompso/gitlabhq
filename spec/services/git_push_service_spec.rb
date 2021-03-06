require 'spec_helper'

describe GitPushService do
  include RepoHelpers

  let (:user)          { create :user }
  let (:project)       { create :project }
  let (:service) { GitPushService.new }

  before do
    @blankrev = Gitlab::Git::BLANK_SHA
    @oldrev = sample_commit.parent_id
    @newrev = sample_commit.id
    @ref = 'refs/heads/master'
  end

  describe 'Push branches' do
    context 'new branch' do
      subject do
        service.execute(project, user, @blankrev, @newrev, @ref)
      end

      it { should be_true }
    end

    context 'existing branch' do
      subject do
        service.execute(project, user, @oldrev, @newrev, @ref)
      end

      it { should be_true }
    end

    context 'rm branch' do
      subject do
        service.execute(project, user, @oldrev, @blankrev, @ref)
      end

      it { should be_true }
    end
  end

  describe "Git Push Data" do
    before do
      service.execute(project, user, @oldrev, @newrev, @ref)
      @push_data = service.push_data
      @commit = project.repository.commit(@newrev)
    end

    subject { @push_data }

    it { should include(before: @oldrev) }
    it { should include(after: @newrev) }
    it { should include(ref: @ref) }
    it { should include(user_id: user.id) }
    it { should include(user_name: user.name) }
    it { should include(project_id: project.id) }

    context "with repository data" do
      subject { @push_data[:repository] }

      it { should include(name: project.name) }
      it { should include(url: project.url_to_repo) }
      it { should include(description: project.description) }
      it { should include(homepage: project.web_url) }
    end

    context "with commits" do
      subject { @push_data[:commits] }

      it { should be_an(Array) }
      it { should have(1).element }

      context "the commit" do
        subject { @push_data[:commits].first }

        it { should include(id: @commit.id) }
        it { should include(message: @commit.safe_message) }
        it { should include(timestamp: @commit.date.xmlschema) }
        it { should include(url: "#{Gitlab.config.gitlab.url}/#{project.to_param}/commit/#{@commit.id}") }

        context "with a author" do
          subject { @push_data[:commits].first[:author] }

          it { should include(name: @commit.author_name) }
          it { should include(email: @commit.author_email) }
        end
      end
    end
  end

  describe "Push Event" do
    before do
      service.execute(project, user, @oldrev, @newrev, @ref)
      @event = Event.last
    end

    it { @event.should_not be_nil }
    it { @event.project.should == project }
    it { @event.action.should == Event::PUSHED }
    it { @event.data.should == service.push_data }
  end

  describe "Web Hooks" do
    context "execute web hooks" do
      it "when pushing a branch for the first time" do
        project.should_receive(:execute_hooks)
        project.default_branch.should == "master"
        project.protected_branches.should_receive(:create).with({ name: "master" })
        service.execute(project, user, @blankrev, 'newrev', 'refs/heads/master')
      end

      it "when pushing new commits to existing branch" do
        project.should_receive(:execute_hooks)
        service.execute(project, user, 'oldrev', 'newrev', 'refs/heads/master')
      end

      it "when pushing tags" do
        project.should_not_receive(:execute_hooks)
        service.execute(project, user, 'newrev', 'newrev', 'refs/tags/v1.0.0')
      end
    end
  end

  describe "cross-reference notes" do
    let(:issue) { create :issue, project: project }
    let(:commit_author) { create :user }
    let(:commit) { project.repository.commit }

    before do
      commit.stub({
        safe_message: "this commit \n mentions ##{issue.id}",
        references: [issue],
        author_name: commit_author.name,
        author_email: commit_author.email
      })
      project.repository.stub(commits_between: [commit])
    end

    it "creates a note if a pushed commit mentions an issue" do
      Note.should_receive(:create_cross_reference_note).with(issue, commit, commit_author, project)

      service.execute(project, user, @oldrev, @newrev, @ref)
    end

    it "only creates a cross-reference note if one doesn't already exist" do
      Note.create_cross_reference_note(issue, commit, user, project)

      Note.should_not_receive(:create_cross_reference_note).with(issue, commit, commit_author, project)

      service.execute(project, user, @oldrev, @newrev, @ref)
    end

    it "defaults to the pushing user if the commit's author is not known" do
      commit.stub(author_name: 'unknown name', author_email: 'unknown@email.com')
      Note.should_receive(:create_cross_reference_note).with(issue, commit, user, project)

      service.execute(project, user, @oldrev, @newrev, @ref)
    end

    it "finds references in the first push to a non-default branch" do
      project.repository.stub(:commits_between).with(@blankrev, @newrev).and_return([])
      project.repository.stub(:commits_between).with("master", @newrev).and_return([commit])

      Note.should_receive(:create_cross_reference_note).with(issue, commit, commit_author, project)

      service.execute(project, user, @blankrev, @newrev, 'refs/heads/other')
    end

    it "finds references in the first push to a default branch" do
      project.repository.stub(:commits_between).with(@blankrev, @newrev).and_return([])
      project.repository.stub(:commits).with(@newrev).and_return([commit])

      Note.should_receive(:create_cross_reference_note).with(issue, commit, commit_author, project)

      service.execute(project, user, @blankrev, @newrev, 'refs/heads/master')
    end
  end

  describe "closing issues from pushed commits" do
    let(:issue) { create :issue, project: project }
    let(:other_issue) { create :issue, project: project }
    let(:commit_author) { create :user }
    let(:closing_commit) { project.repository.commit }

    before do
      closing_commit.stub({
        issue_closing_regex: /^([Cc]loses|[Ff]ixes) #\d+/,
        safe_message: "this is some work.\n\ncloses ##{issue.iid}",
        author_name: commit_author.name,
        author_email: commit_author.email
      })

      project.repository.stub(commits_between: [closing_commit])
    end

    it "closes issues with commit messages" do
      service.execute(project, user, @oldrev, @newrev, @ref)

      Issue.find(issue.id).should be_closed
    end

    it "doesn't create cross-reference notes for a closing reference" do
      expect {
        service.execute(project, user, @oldrev, @newrev, @ref)
      }.not_to change { Note.where(project_id: project.id, system: true, commit_id: closing_commit.id).count }
    end

    it "doesn't close issues when pushed to non-default branches" do
      project.stub(default_branch: 'durf')

      # The push still shouldn't create cross-reference notes.
      expect {
        service.execute(project, user, @oldrev, @newrev, 'refs/heads/hurf')
      }.not_to change { Note.where(project_id: project.id, system: true).count }

      Issue.find(issue.id).should be_opened
    end
  end
end

