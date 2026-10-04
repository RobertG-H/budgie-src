namespace :user do
  desc "Permanently delete the user with EMAIL, with their identities, sessions, budget and invite (asks for confirmation)"
  task delete: :environment do |task|
    email = ENV["EMAIL"].presence or abort "Usage: bin/rails #{task.name} EMAIL=someone@example.com"
    user = User.find_by(email: email) or abort "No user has the email #{User.normalize_value_for(:email, email)}."

    count = ->(n, noun) { "#{n} #{noun.pluralize(n)}" }

    budget = if user.budget
      counts = [
        [ user.budget.envelopes.count, "envelope" ], [ user.budget.deposits.count, "deposit" ], [ user.budget.assignments.count, "assignment" ],
        [ user.budget.spends.count, "spend" ], [ user.budget.refunds.count, "refund" ],
        [ user.budget.envelope_reallocations.count + user.budget.ready_to_assign_reallocations.count, "reallocation" ],
        [ user.budget.csv_formats.count, "CSV format" ], [ user.budget.accounts.count, "account" ], [ user.budget.imports.count, "import" ],
        [ user.budget.bank_transactions.count, "bank transaction" ], [ user.budget.filing_rules.count, "filing rule" ]
      ]
      "their budget with #{counts.map { |n, noun| count.(n, noun) }.to_sentence(last_word_connector: " and ")}"
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
