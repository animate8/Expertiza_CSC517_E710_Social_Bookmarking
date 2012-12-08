class SignupController < ApplicationController
  require 'rgl/adjacency'
  require 'rgl/dot'
  require 'graph/graphviz_dot'
  require 'rgl/topsort'

  def create_team(assignment_id)
    assignment = Assignment.find(assignment_id)
    #check_for_existing_team_name(parent,generate_team_name(parent.name))
    teamname = generate_team_name(assignment.name)
    team = AssignmentTeam.create(:name => teamname, :parent_id => assignment.id)
    TeamNode.create(:parent_id => assignment.id, :node_object_id => team.id)
    team
  end

  def generate_team_name(teamnameprefix)
    counter = 1
    while (true)
      teamname = teamnameprefix + "_Team#{counter}"
      if (!Team.find_by_name(teamname))
        return teamname
      end
      counter=counter+1
    end
  end

  def create_team_users(user, team_id)
    #user = User.find_by_name(params[:user][:name].strip)
    if !user
      urlCreate = url_for :controller => 'users', :action => 'new'
      flash[:error] = "\"#{params[:user][:name].strip}\" is not defined. Please <a href=\"#{urlCreate}\">create</a> this user before continuing."
    end
    team = Team.find(team_id)
    team.add_member(user)
  end

  def get_team_details(assignment_id, topic_id)

    query = "select t.name, t.comments_for_advertisement, p.handle,t.id as team_id, p.id as participant_id, p.topic_id as topic_id, p.parent_id as assignment_id"
    query = query + " from teams t, teams_users tu, participants p"
    query = query + " where"
    query = query + " p.parent_id = '#{assignment_id}' and"
    query = query + " p.topic_id = '#{topic_id}' and"
    query = query + " t.parent_id = p.parent_id and"
    query = query + " tu.user_id = p.user_id and"
    query = query + " t.id = tu.team_id"
    query = query + " group by t.name;"

    SignUpTopic.find_by_sql(query)

  end
  def team_details
    if !(assignment = Assignment.find(params[:assignment_id])).nil? and !(topic = SignUpTopic.find(params[:id])).nil?
      @results =get_team_details(assignment.id, topic.id)
      @results.each do |result|
        result.attributes().each do |attr|
          if attr[0].equal? "name"
            @current_team_name = attr[1]
          end
        end
      end
      @results.each { |result|
        @team_members = ""
        TeamsUser.find_all_by_team_id(result[:team_id]).each { |teamuser|
          puts 'Userblaahsdb asd' +User.find(teamuser.user_id).to_json
          @team_members+=User.find(teamuser.user_id).name+" "
        }
      }
      #@team_members = find_team_members(topic)
    end
  end

  def signup_topics
    @assignment_id = params[:id]
    @sign_up_topics = SignUpTopic.find(:all, :conditions => ['assignment_id = ?', params[:id]])
    @slots_filled = SignUpTopic.find_slots_filled(params[:id])
    @slots_waitlisted = SignUpTopic.find_slots_waitlisted(params[:id])
    @show_actions = true

    #find whether assignment is team assignment
    assignment = Assignment.find(params[:id])


    if !assignment.staggered_deadline? and assignment.due_dates.find_by_deadline_type_id(1).due_at < Time.now
      @show_actions = false
    end

    #Find whether the user has signed up for any topics; if so the user won't be able to
    #sign up again unless the former was a waitlisted topic
    #if team assignment, then team id needs to be passed as parameter else the user's id
    if assignment.team_assignment == true
      users_team = SignedUpUser.find_team_users(params[:id], (session[:user].id))

      if users_team.size == 0
        @selected_topics = nil
      else
        #TODO: fix this; cant use 0
        @selected_topics = otherConfirmedTopicforUser(params[:id], users_team[0].t_id)
      end
    else
      @selected_topics = otherConfirmedTopicforUser(params[:id], session[:user].id)
    end
  end

  #this function is used to delete a previous signup
  def delete_signup
    delete_signup_for_topic(params[:assignment_id], params[:id])
    redirect_to :action => 'signup_topics', :id => params[:assignment_id]
  end

  def delete_signup_for_topic(assignment_id, topic_id)
    #find whether assignment is team assignment
    assignment = Assignment.find(assignment_id)

    #making sure that the drop date deadline hasn't passed
    dropDate = DueDate.find(:first, :conditions => {:assignment_id => assignment.id, :deadline_type_id => '6'})
    if (!dropDate.nil? && dropDate.due_at < Time.now)
      flash[:error] = "You cannot drop this topic because the drop deadline has passed."
    else
      #if team assignment find the creator id from teamusers table and teams
      if assignment.team_assignment == true
        #users_team will contain the team id of the team to which the user belongs
        users_team = SignedUpUser.find_team_users(assignment_id, (session[:user].id))
        signup_record = SignedUpUser.find_by_topic_id_and_creator_id(topic_id, users_team[0].t_id)
      else
        signup_record = SignedUpUser.find_by_topic_id_and_creator_id(topic_id, session[:user].id)
      end

      #if a confirmed slot is deleted then push the first waiting list member to confirmed slot if someone is on the waitlist
      if signup_record.is_waitlisted == false
        #find the first wait listed user if exists
        first_waitlisted_user = SignedUpUser.find_by_topic_id_and_is_waitlisted(topic_id, true)

        if !first_waitlisted_user.nil?
          # As this user is going to be allocated a confirmed topic, all of his waitlisted topic signups should be purged
          ### Bad policy!  Should be changed! (once users are allowed to specify waitlist priorities) -efg
          first_waitlisted_user.is_waitlisted = false
          first_waitlisted_user.save

          #update the participants details
          if assignment.team_assignment?
            user_id = TeamsUser.find(:first, :conditions => {:team_id => first_waitlisted_user.creator_id}).user_id
            participant = Participant.find_by_user_id_and_parent_id(user_id, assignment.id)
          else
            participant = Participant.find_by_user_id_and_parent_id(first_waitlisted_user.creator_id, assignment.id)
          end
          participant.update_topic_id(topic_id)

          SignUpTopic.cancel_all_waitlists(first_waitlisted_user.creator_id, assignment_id)
        end
      end

      if !signup_record.nil?
        participant = Participant.find_by_user_id_and_parent_id(session[:user].id, assignment_id)
        #update participant's topic id to nil
        participant.update_topic_id(nil)
        signup_record.destroy
      end
    end #end condition for 'drop deadline' check
  end

  def signup
    #find the assignment to which user is signing up
    assignment = Assignment.find(params[:assignment_id])

    #check whether team assignment. This is to decide whether a team_id or user_id should be the creator_id
    if assignment.team_assignment == true

      #check whether the user already has a team for this assignment
      users_team = SignedUpUser.find_team_users(params[:assignment_id], (session[:user].id))

      if users_team.size == 0
        #if team is not yet created, create new team.
        team = create_team(params[:assignment_id])
        user = User.find(session[:user].id)
        teamuser = create_team_users(user, team.id)
        confirmationStatus = confirmTopic(team.id, params[:id], params[:assignment_id])
      else
        confirmationStatus = confirmTopic(users_team[0].t_id, params[:id], params[:assignment_id])
      end
    else
      confirmationStatus = confirmTopic(session[:user].id, params[:id], params[:assignment_id])
    end
    redirect_to :action => 'signup_topics', :id => params[:assignment_id]
  end

  # When using this method when creating fields, update race conditions by using db transactions
  def slotAvailable?(topic_id)
    SignUpTopic.slotAvailable?(topic_id)
  end

  def otherConfirmedTopicforUser(assignment_id, creator_id)
    user_signup = SignedUpUser.find_user_signup_topics(assignment_id, creator_id)
    user_signup
  end

  def confirmTopic(creator_id, topic_id, assignment_id)
    #check whether user has signed up already
    user_signup = otherConfirmedTopicforUser(assignment_id, creator_id)

    sign_up = SignedUpUser.new
    sign_up.topic_id = params[:id]
    sign_up.creator_id = creator_id

    result = false
    if user_signup.size == 0

      # Using a DB transaction to ensure atomic inserts
      ActiveRecord::Base.transaction do
        #check whether slots exist (params[:id] = topic_id) or has the user selected another topic
        if slotAvailable?(topic_id)
          sign_up.is_waitlisted = false

          #Update topic_id in participant table with the topic_id
          participant = Participant.find_by_user_id_and_parent_id(session[:user].id, assignment_id)

          participant.update_topic_id(topic_id)
        else
          sign_up.is_waitlisted = true
        end
        if sign_up.save
          result = true
        end
      end
    else
      #If all the topics choosen by the user are waitlisted,
      for user_signup_topic in user_signup
        if user_signup_topic.is_waitlisted == false
          flash[:error] = "You have already signed up for a topic."
          return false
        end
      end

      # Using a DB transaction to ensure atomic inserts
      ActiveRecord::Base.transaction do
        #check whether user is clicking on a topic which is not going to place him in the waitlist
        if !slotAvailable?(topic_id)
          sign_up.is_waitlisted = true
          if sign_up.save
            result = true
          end
        else
          #if slot exist, then confirm the topic for the user and delete all the waitlist for this user
          SignUpTopic.cancel_all_waitlists(creator_id, assignment_id)
          sign_up.is_waitlisted = false
          sign_up.save

          participant = Participant.find_by_user_id_and_parent_id(session[:user].id, assignment_id)
          participant.update_topic_id(topic_id)
          result = true
        end
      end
    end

    result
  end
end
