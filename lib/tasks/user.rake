namespace :user do
  desc "Permanently delete the user with EMAIL, with their identities, sessions, budget and invite (asks for confirmation)"
  task delete: :environment do |task|
    email = ENV["EMAIL"].presence or abort "Usage: bin/rails #{task.name} EMAIL=someone@example.com"
    user = User.find_by(email: email) or abort "No user has the email #{User.normalize_value_for(:email, email)}."

    count = ->(n, noun) { "#{n} #{noun.pluralize(n)}" }

    budget = if user.budget
      "their budget with #{count.(user.budget.envelopes.count, "envelope")}, " \
        "#{count.(user.budget.deposits.count, "deposit")}, #{count.(user.budget.assignments.count, "assignment")}, " \
        "#{count.(user.budget.spends.count, "spend")} and #{count.(user.budget.refunds.count, "refund")}"
    else
      "no budget"
    end
    puts "This permanently deletes #{user.email} (#{user.name.presence || "no name"}), " \
      "their #{count.(user.identities.count, "identity")}, #{count.(user.sessions.count, "session")}, " \
      "#{budget} and #{user.invite ? "their invite" : "no invite"}."
    print "Type the email to confirm: "
    abort "Not deleted." unless $stdin.gets.to_s.strip.downcase == user.email

    user.destroy!
    puts "Deleted #{user.email}. They can be invited again with invite:create."
  end
end
