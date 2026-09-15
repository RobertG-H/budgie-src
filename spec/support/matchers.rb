# Lets `change` be negated inside a compound expectation, e.g. `.to not_change(Invite, :count).and change(...)`.
RSpec::Matchers.define_negated_matcher :not_change, :change
