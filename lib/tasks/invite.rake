# Thin wrappers over Invite's operations, which can also be called from bin/rails console.
# Each task exits non-zero with a message when it fails.
namespace :invite do
  # Runs the block with ENV["EMAIL"], turning refusals and invalid emails into a failed exit.
  run_with_email = ->(task, &block) do
    email = ENV["EMAIL"].presence or abort "Usage: bin/rails #{task.name} EMAIL=someone@example.com"
    block.call(email)
  rescue Invite::Refused, ActiveRecord::RecordInvalid => error
    abort error.message
  end

  desc "Invite EMAIL and send the invite email (a revoked email is invited again)"
  task create: :environment do |task|
    run_with_email.call(task) { |email| puts "Invited #{Invite.issue!(email).email}." }
  end

  desc "Send EMAIL's pending invite again"
  task resend: :environment do |task|
    run_with_email.call(task) { |email| puts "Resent the invite to #{Invite.resend!(email).email}." }
  end

  desc "Revoke EMAIL's pending invite"
  task revoke: :environment do |task|
    run_with_email.call(task) { |email| puts "Revoked the invite for #{Invite.revoke!(email).email}." }
  end

  desc "List invites, optionally only those with STATUS=pending, accepted or revoked"
  task list: :environment do
    status = ENV["STATUS"].presence
    abort "STATUS must be one of: #{Invite::STATUSES.join(", ")}" if status && Invite::STATUSES.exclude?(status)

    invites = (status ? Invite.public_send(status) : Invite.all).order(:created_at)
    next puts("No invites.") if invites.none?

    date = ->(time) { time&.to_fs(:db) || "-" }
    rows = invites.map { |invite| [ invite.email, invite.status, date.(invite.created_at), date.(invite.accepted_at), date.(invite.revoked_at) ] }
    rows.unshift([ "EMAIL", "STATUS", "INVITED", "ACCEPTED", "REVOKED" ])
    widths = rows.transpose.map { |column| column.map(&:length).max }

    rows.each { |row| puts row.zip(widths).map { |cell, width| cell.ljust(width) }.join("  ").rstrip }
  end
end
