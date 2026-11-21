# Says why something that needed Plaid wasn't done, in words for an alert: Disconnect, and deleting a bank connection's last Account, both remove the Item at Plaid first
# and are refused, with nothing changed, when it can't be done.
module PlaidRefusal
  extend ActiveSupport::Concern

  # What goes wrong when Plaid is asked to remove an Item: it can't be reached or refuses (PlaidApi::Error, whose message is Plaid's display message or its code and never a
  # token or what it answered), or the key the token is kept under has gone, so it can't be read to tell Plaid.
  REFUSALS = [ PlaidApi::Error, ActiveRecord::Encryption::Errors::Decryption ].freeze

  private
    # `not_done` is what wasn't done ("TD Canada Trust wasn't disconnected"), and `bank` the bank's name.
    def plaid_refusal(error, not_done, bank)
      if error.is_a?(ActiveRecord::Encryption::Errors::Decryption)
        "Budgie can't read the saved connection to #{bank}, so #{not_done} and nothing was changed."
      else
        "#{error.message.delete_suffix(".")}, so #{not_done} and nothing was changed. Try again later."
      end
    end
end
