namespace :budget do
  desc "Start the new months of every budget that's behind, as the hourly job does"
  task start_months: :environment do
    behind = Budget.with_months_to_start.count
    next puts("No budget has a month to start.") if behind.zero?

    StartNewMonthsJob.perform_now
    puts "Started the new months of #{behind} #{"budget".pluralize(behind)}."
  end

  desc "Change the currency of EMAIL's budget to CURRENCY, without converting amounts (asks for confirmation)"
  task currency: :environment do |task|
    email, currency = ENV["EMAIL"].presence, ENV["CURRENCY"].presence
    abort "Usage: bin/rails #{task.name} EMAIL=someone@example.com CURRENCY=CAD" unless email && currency

    user = User.find_by(email: email) or abort "No user has the email #{User.normalize_value_for(:email, email)}."
    budget = user.budget or abort "#{user.email} hasn't set up a budget."
    currency = currency.strip.upcase
    abort "#{currency} isn't supported. Choose one of: #{Budget::CURRENCIES.keys.join(", ")}." unless Budget::CURRENCIES.key?(currency)
    next puts("#{user.email}'s budget is already in #{currency}.") if budget.currency == currency

    puts "This changes #{user.email}'s budget from #{budget.currency} to #{currency}."
    puts "Amounts aren't converted: each keeps its number and is shown in #{currency}."
    print "Type the email to confirm: "
    abort "Not changed." unless $stdin.gets.to_s.strip.downcase == user.email

    budget.update!(currency: currency)
    puts "Changed #{user.email}'s budget to #{currency}."
  end
end
