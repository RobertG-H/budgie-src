# Tooling for local development only: /styleguide and /dev/sign_in. See DESIGN.md.
module Dev
  # The user db/seeds/development.rb creates and /dev/sign_in signs in as. It has no Identity, so nobody can
  # sign in as it through Google.
  USER_EMAIL = "dev@budgie.test"
end
