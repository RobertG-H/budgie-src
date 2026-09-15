require "rails_helper"

RSpec.describe InviteMailer, type: :mailer do
  describe "#invite" do
    let(:invite) { build(:invite, email: "robin@example.com") }
    let(:mail) { InviteMailer.with(invite: invite).invite }

    it "is sent to the invited address from MAILER_FROM's development fallback" do
      expect(mail.to).to eq([ "robin@example.com" ])
      expect(mail.from).to eq([ "no-reply@localhost" ])
      expect(mail.subject).to eq("You're invited to Budgie")
    end

    it "asks for this exact address and links to the sign-in page, in HTML and text" do
      expect(mail.html_part.body.to_s).to include("<strong>robin@example.com</strong>", %(href="http://example.com/sign_in"))
      expect(mail.text_part.body.to_s).to include("this exact address: robin@example.com", "http://example.com/sign_in")
    end
  end
end
