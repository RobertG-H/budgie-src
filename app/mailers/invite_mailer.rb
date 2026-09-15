class InviteMailer < ApplicationMailer
  def invite
    @invite = params[:invite]

    mail to: @invite.email, subject: "You're invited to Budgie"
  end
end
