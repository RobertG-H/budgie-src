namespace :user do
  desc "Permanently delete the user with EMAIL, with their identities, sessions and invite (asks for confirmation)"
  task delete: :environment do |task|
    email = ENV["EMAIL"].presence or abort "Usage: bin/rails #{task.name} EMAIL=someone@example.com"
    user = User.find_by(email: email) or abort "No user has the email #{User.normalize_value_for(:email, email)}."

    identities = user.identities.count
    sessions = user.sessions.count
    puts "This permanently deletes #{user.email} (#{user.name.presence || "no name"}), " \
      "their #{identities} #{"identity".pluralize(identities)}, #{sessions} #{"session".pluralize(sessions)} " \
      "and #{user.invite ? "their invite" : "no invite"}."
    print "Type the email to confirm: "
    abort "Not deleted." unless $stdin.gets.to_s.strip.downcase == user.email

    user.destroy!
    puts "Deleted #{user.email}. They can be invited again with invite:create."
  end
end
