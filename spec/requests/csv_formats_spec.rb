require "rails_helper"

RSpec.describe "CSV formats", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }
  let(:others_format) { create(:budget_csv_format, name: "Someone else's") }

  before { sign_in_as budget.user }

  # What a person types into the form for a signed amount in the third column of a three-column sample.
  let(:format_params) do
    { name: "My bank", rows_to_skip: "1", column_count: "3", date_column: "1", date_order: "year_month_day",
      description_columns: "2", amount_style: "signed", amount_column: "3", invert_sign: "0" }
  end

  describe "GET /csv_formats" do
    it "lists the budget's CSV formats alphabetically, and no one else's" do
      create(:budget_csv_format, budget: budget, name: "tangerine")
      create(:budget_csv_format, budget: budget, name: "CIBC")
      create(:budget_csv_format, budget: budget, name: "Amex")
      others_format

      get csv_formats_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "CSV formats · Budgie"
      assert_select "h1", text: "CSV formats"
      expect(css_select("main ul.list li a span.font-semibold").map(&:text)).to eq([ "Amex", "CIBC", "tangerine" ])
      expect(response.body).not_to include("Someone else")
    end

    it "links each to where it's edited, and says how it reads a file" do
      format = create(:budget_csv_format, budget: budget, name: "CIBC", date_column: 1, date_order: "month_day_year", description_columns: [ 2 ], amount_column: 3)

      get csv_formats_path

      assert_select "main ul.list li a[href='#{edit_csv_format_path(format)}']" do
        assert_select "span.font-semibold", text: "CIBC"
        assert_select "span.text-base-content\\/70", text: "Date in column 1, in month, day, year order. Description in column 2. Amount in column 3, with money out as a negative amount."
      end
    end

    it "says how it reads each style of amount, and an inverted sign" do
      create(:budget_csv_format, :in_and_out, budget: budget, name: "Separate")
      create(:budget_csv_format, :direction, budget: budget, name: "Directed", description_columns: [ 2, 1 ], invert_sign: true)

      get csv_formats_path

      expect(response.body).to include("Description in column 2. Money in is in column 4, and money out is in column 3.")
      expect(response.body).to include("Description in columns 2 and 1. Amount in column 3, with money in when column 4 says Credit. The sign is inverted.")
    end

    it "has a link to start one" do
      get csv_formats_path

      assert_select "main a.btn[href='#{new_csv_format_path}']", text: "New CSV format"
    end

    it "says when there are none, with a way to start one" do
      get csv_formats_path

      assert_select "main", text: /You don't have any CSV formats yet/
      assert_select "main .border-dashed a.btn[href='#{new_csv_format_path}']", text: "New CSV format"
    end

    it "requires sign-in" do
      delete session_path

      get csv_formats_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "GET /csv_formats/new" do
    it "shows a form with a field for everything a CSV format has, and the sample it's built from" do
      get new_csv_format_path

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "New CSV format · Budgie"
      assert_select "h1", text: "New CSV format"
      assert_select "form[action='#{csv_formats_path}'][method=post][enctype='multipart/form-data']" do
        assert_select "label", text: "Name"
        assert_select "input[type=text][name='csv_format[name]'][required]"
        assert_select "label", text: "Sample file"
        assert_select "input[type=file][name='csv_format[sample]']"
        assert_select "label", text: "Rows to skip"
        assert_select "input[type=number][name='csv_format[rows_to_skip]'][min='0'][value='0']"
        assert_select "label", text: "Date column"
        assert_select "input[type=number][name='csv_format[date_column]'][min='1']"
        assert_select "label", text: "Date order"
        assert_select "select[name='csv_format[date_order]'] option", count: 4 # A prompt and the three orders.
        assert_select "label", text: "Description columns"
        assert_select "input[type=text][name='csv_format[description_columns]']"
        assert_select "legend", text: "Amount style"
        assert_select "input[type=radio][name='csv_format[amount_style]']", count: 3
        assert_select "input[type=radio][name='csv_format[amount_style]'][value=signed][checked]"
        assert_select "label", text: "Amount column"
        assert_select "label", text: "Money in column"
        assert_select "label", text: "Money out column"
        assert_select "label", text: "Direction column"
        assert_select "label", text: "Direction for money in"
        assert_select "label", text: "Invert sign"
        assert_select "input[type=checkbox][name='csv_format[invert_sign]']"
        assert_select "input[type=submit]"
      end
    end

    it "offers the three date orders, each with what it looks like, after a prompt" do
      get new_csv_format_path

      expect(css_select("select[name='csv_format[date_order]'] option").map { |option| option.text.strip })
        .to eq([ "Choose a date order", "Year, month, day (2026-10-07)", "Month, day, year (10/07/2026)", "Day, month, year (07/10/2026)" ])
    end

    it "has a button that previews how the sample reads, which sends the form somewhere else, and Cancel back to the list" do
      get new_csv_format_path

      assert_select "button[type=submit][formaction='#{csv_format_preview_path}'][formnovalidate][name=_method][value=post]", text: "Preview"
      assert_select "a.btn[href='#{csv_formats_path}']", text: "Cancel"
    end

    it "starts with no sample, so there's no preview and no grid to show yet" do
      get new_csv_format_path

      assert_select "#csv-format-grid", text: /Choose a sample file/
      assert_select "#csv-format-preview", text: /Choose a sample file/
      assert_select "#csv-format-grid input[type=hidden][name='csv_format[column_count]']"
    end

    it "requires sign-in" do
      delete session_path

      get new_csv_format_path

      expect(response).to redirect_to(sign_in_path)
    end
  end

  describe "POST /csv_formats" do
    it "adds a CSV format to the budget, and goes back to the list" do
      expect { post csv_formats_path, params: { csv_format: format_params } }.to change(budget.csv_formats, :count).by(1)

      expect(budget.csv_formats.sole).to have_attributes(
        name: "My bank", rows_to_skip: 1, column_count: 3, date_column: 1, date_order: "year_month_day", description_columns: [ 2 ],
        amount_style: "signed", amount_column: 3, invert_sign: false
      )
      expect(response).to redirect_to(csv_formats_path)
      follow_redirect!
      assert_select "[role=status]", text: "CSV format added."
    end

    it "chooses the date order from the sample when it wasn't chosen, as a form without JavaScript sends it" do
      sample = Rack::Test::UploadedFile.new(file_fixture("signed-sample.csv"), "text/csv")

      post csv_formats_path, params: { csv_format: format_params.merge(date_order: "", sample: sample) }

      expect(budget.csv_formats.sole.date_order).to eq("year_month_day")
    end

    it "saves each amount style with its columns" do
      post csv_formats_path, params: { csv_format: format_params.merge(name: "Separate", amount_style: "in_and_out", amount_column: "", money_in_column: "4", money_out_column: "3", column_count: "4") }
      post csv_formats_path, params: { csv_format: format_params.merge(name: "Directed", amount_style: "direction", direction_column: "4", money_in_value: " Credit ", column_count: "4") }

      expect(budget.csv_formats.find_by!(name: "Separate")).to have_attributes(amount_column: nil, money_in_column: 4, money_out_column: 3)
      expect(budget.csv_formats.find_by!(name: "Directed")).to have_attributes(amount_column: 3, direction_column: 4, money_in_value: "Credit")
    end

    it "takes the description columns as the numbers typed, and the sign inverted when it's ticked" do
      post csv_formats_path, params: { csv_format: format_params.merge(description_columns: "2, 1", invert_sign: "1") }

      expect(budget.csv_formats.sole).to have_attributes(description_columns: [ 2, 1 ], invert_sign: true)
    end

    it "doesn't keep the sample, which is only sent so a preview can be made of it" do
      sample = Rack::Test::UploadedFile.new(file_fixture("signed-sample.csv"), "text/csv")

      expect { post csv_formats_path, params: { csv_format: format_params.merge(sample: sample) } }
        .to change(Budget::CsvFormat, :count).by(1)

      expect(Budget::CsvFormat.column_names).not_to include("sample", "file", "contents", "content")
    end

    describe "with the sample it was built from, which is sent with the form" do
      def sample(text = nil)
        text ? Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "sample.csv") : Rack::Test::UploadedFile.new(file_fixture("signed-sample.csv"), "text/csv")
      end

      it "takes the column count from the sample, which is the sample's whatever the form says, or doesn't, as without JavaScript" do
        post csv_formats_path, params: { csv_format: format_params.except(:column_count).merge(sample: sample) }

        expect(budget.csv_formats.sole.column_count).to eq(3)

        post csv_formats_path, params: { csv_format: format_params.merge(name: "Another", column_count: "9", sample: sample) }

        expect(budget.csv_formats.find_by!(name: "Another").column_count).to eq(3)
      end

      it "takes it from the first row the format reads, so the rows to skip decide it" do
        text = "Account: Chequing\nDate,Description,Amount,Extra\n2026-09-01,Paycheck,10.00,x\n"

        post csv_formats_path, params: { csv_format: format_params.merge(rows_to_skip: "2", amount_column: "4", sample: sample(text)) }

        expect(budget.csv_formats.sole).to have_attributes(column_count: 4, rows_to_skip: 2, amount_column: 4)
      end

      it "refuses a sample that can't be read, saying why, and creates nothing" do
        expect { post csv_formats_path, params: { csv_format: format_params.merge(sample: sample("2026-09-01,Caf\xE9,-5.00\n".b)) } }.not_to change(Budget::CsvFormat, :count)

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again."
      end

      it "says the columns must be in the sample's, when it names one that isn't" do
        post csv_formats_path, params: { csv_format: format_params.merge(date_column: "5", sample: sample) }

        expect(response).to have_http_status(:unprocessable_content)
        assert_select "[role=alert] li", text: "Date column must be one of the sample's columns, 1 to 3"
      end

      it "doesn't keep it, or read it past the request" do
        expect { post csv_formats_path, params: { csv_format: format_params.merge(sample: sample) } }.to change(Budget::CsvFormat, :count).by(1)

        expect(Budget::CsvFormat.column_names).not_to include("sample", "file", "contents", "content")
      end

      it "takes it again when a format is changed with a new sample, and keeps the old one without" do
        format = create(:budget_csv_format, budget: budget, column_count: 3)

        patch csv_format_path(format), params: { csv_format: { name: "Wider", amount_style: "in_and_out", money_in_column: "4", money_out_column: "3", sample: sample("a,b,c,d\n") } }

        expect(format.reload).to have_attributes(column_count: 4, amount_style: "in_and_out")

        patch csv_format_path(format), params: { csv_format: { name: "Same width" } }

        expect(format.reload.column_count).to eq(4)
      end
    end

    it "refuses what's wrong with it, keeping what was entered, and creates nothing" do
      expect { post csv_formats_path, params: { csv_format: format_params.merge(name: "", date_column: "7", date_order: "", description_columns: "2, payee", amount_style: "direction", direction_column: "3", money_in_value: "") } }
        .not_to change(Budget::CsvFormat, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"
      assert_select "[role=alert] li", text: "Date column must be one of the sample's columns, 1 to 3"
      assert_select "[role=alert] li", text: "Date order must be chosen"
      assert_select "[role=alert] li", text: /Description columns must be one of the sample's columns/
      assert_select "[role=alert] li", text: "Direction column can't be the same column as the amount"
      assert_select "[role=alert] li", text: "Direction for money in can't be blank"
      assert_select "input[name='csv_format[date_column]'][value='7'][aria-invalid=true]"
      assert_select "input[name='csv_format[description_columns]'][value='2, 0']"
      assert_select "input[type=radio][value=direction][checked]"
    end

    it "refuses a name that's already used, in another case" do
      create(:budget_csv_format, budget: budget, name: "My bank")

      expect { post csv_formats_path, params: { csv_format: format_params.merge(name: "my BANK") } }.not_to change(Budget::CsvFormat, :count)

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name has already been taken"
    end

    it "allows a name another budget has used" do
      create(:budget_csv_format, name: "My bank")

      expect { post csv_formats_path, params: { csv_format: format_params } }.to change(budget.csv_formats, :count).by(1)
    end

    it "refuses a format that wasn't built from a sample, since it has no column count" do
      post csv_formats_path, params: { csv_format: format_params.except(:column_count) }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Sample file must be chosen, so the columns can be read from it"
    end

    it "never takes the budget from the params" do
      other = create(:budget)

      post csv_formats_path, params: { csv_format: format_params.merge(budget_id: other.id) }

      expect(other.csv_formats).to be_empty
      expect(budget.csv_formats.count).to eq(1)
    end

    it "is a bad request without a csv_format" do
      post csv_formats_path

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "GET /csv_formats/:id/edit" do
    let!(:format) do
      create(:budget_csv_format, :direction, budget: budget, name: "CIBC", rows_to_skip: 1, description_columns: [ 2, 1 ], money_in_value: "Credit", invert_sign: true)
    end

    it "shows the form with what the format has, ready to change" do
      get edit_csv_format_path(format)

      expect(response).to have_http_status(:ok)
      assert_select "title", text: "Edit CSV format · Budgie"
      assert_select "h1", text: "Edit CSV format"
      assert_select "form[action='#{csv_format_path(format)}'][method=post] input[name=_method][value=patch]"
      assert_select "input[name='csv_format[name]'][value=CIBC]"
      assert_select "input[name='csv_format[rows_to_skip]'][value='1']"
      assert_select "input[name='csv_format[column_count]'][value='4']"
      assert_select "input[name='csv_format[date_column]'][value='1']"
      assert_select "select[name='csv_format[date_order]'] option[selected][value='year_month_day']"
      assert_select "input[name='csv_format[description_columns]'][value='2, 1']"
      assert_select "input[type=radio][value=direction][checked]"
      assert_select "input[name='csv_format[amount_column]'][value='3']"
      assert_select "input[name='csv_format[direction_column]'][value='4']"
      assert_select "input[name='csv_format[money_in_value]'][value=Credit]"
      assert_select "input[type=checkbox][name='csv_format[invert_sign]'][checked]"
    end

    it "carries which format it is, so a preview of it can say so, and has no sample until one is chosen again" do
      get edit_csv_format_path(format)

      assert_select "form input[type=hidden][name=csv_format_id][value='#{format.id}']"
      assert_select "#csv-format-grid", text: /Choose a sample file again/
    end

    it "has a Delete button, and Cancel back to the list" do
      get edit_csv_format_path(format)

      assert_select "form[action='#{csv_format_path(format)}'] input[name=_method][value=delete]"
      assert_select "form[data-turbo-confirm='Delete the CIBC CSV format?']"
      assert_select "a.btn[href='#{csv_formats_path}']", text: "Cancel"
    end

    it "says in the question before deleting it which Accounts it's the default for, which will have none" do
      account = create(:budget_account, budget: format.budget, default_csv_format: format)

      get edit_csv_format_path(format)
      assert_select "form[data-turbo-confirm=\"Delete the CIBC CSV format? It's the default for 1 Account, which will have none.\"]"

      create(:budget_account, budget: format.budget, default_csv_format: format)
      get edit_csv_format_path(format)
      assert_select "form[data-turbo-confirm=\"Delete the CIBC CSV format? It's the default for 2 Accounts, which will have none.\"]"
      expect(account.reload.default_csv_format).to eq(format)
    end

    it "doesn't promise to clear a default when an Import used the format, since the delete is refused and clears nothing" do
      create(:budget_account, budget: format.budget, default_csv_format: format)
      create(:budget_import, account: create(:budget_account, budget: format.budget), csv_format: format)

      get edit_csv_format_path(format)

      assert_select "form[data-turbo-confirm='Delete the CIBC CSV format?']"
    end

    it "is not found for another user's CSV format" do
      get edit_csv_format_path(others_format)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /csv_formats/:id" do
    let!(:format) { create(:budget_csv_format, budget: budget, name: "CIBC", date_order: "month_day_year") }

    it "changes the format, and goes back to the list" do
      patch csv_format_path(format), params: { csv_format: { name: "CIBC Visa", date_order: "day_month_year", invert_sign: "1" } }

      expect(format.reload).to have_attributes(name: "CIBC Visa", date_order: "day_month_year", invert_sign: true)
      expect(response).to redirect_to(csv_formats_path)
      follow_redirect!
      assert_select "[role=status]", text: "CSV format updated."
    end

    it "can change to another amount style, which leaves the old one's columns unset" do
      patch csv_format_path(format), params: { csv_format: { amount_style: "in_and_out", column_count: "4", money_in_column: "4", money_out_column: "3" } }

      expect(format.reload).to have_attributes(amount_style: "in_and_out", amount_column: nil, money_in_column: 4, money_out_column: 3)
    end

    it "refuses what's wrong with it, and changes nothing" do
      patch csv_format_path(format), params: { csv_format: { name: "", date_column: "9" } }

      expect(response).to have_http_status(:unprocessable_content)
      assert_select "[role=alert] li", text: "Name can't be blank"
      assert_select "h1", text: "Edit CSV format"
      expect(format.reload).to have_attributes(name: "CIBC", date_column: 1)
    end

    it "never moves the format to another budget" do
      other = create(:budget)

      patch csv_format_path(format), params: { csv_format: { name: "Moved", budget_id: other.id } }

      expect(format.reload).to have_attributes(name: "Moved", budget_id: budget.id)
    end

    it "is not found for another user's CSV format, which it doesn't change" do
      patch csv_format_path(others_format), params: { csv_format: { name: "Mine now" } }

      expect(response).to have_http_status(:not_found)
      expect(others_format.reload.name).to eq("Someone else's")
    end
  end

  describe "DELETE /csv_formats/:id" do
    let!(:format) { create(:budget_csv_format, budget: budget, name: "CIBC") }

    it "deletes the format, and goes back to the list" do
      expect { delete csv_format_path(format) }.to change(budget.csv_formats, :count).by(-1)

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(csv_formats_path)
      follow_redirect!
      assert_select "[role=status]", text: "CSV format deleted."
    end

    it "deletes a format that's only some Accounts' default, which are left with none" do
      first = create(:budget_account, budget: budget, default_csv_format: format)
      second = create(:budget_account, budget: budget, default_csv_format: format)

      expect { delete csv_format_path(format) }.to change(budget.csv_formats, :count).by(-1)

      expect(response).to redirect_to(csv_formats_path)
      expect([ first, second ].map { |account| account.reload.default_csv_format }).to eq([ nil, nil ])
    end

    it "is not found for another user's CSV format, which it doesn't delete" do
      others_format

      expect { delete csv_format_path(others_format) }.not_to change(Budget::CsvFormat, :count)

      expect(response).to have_http_status(:not_found)
    end

    describe "once an Import has used it" do
      before { create(:budget_import, account: create(:budget_account, budget: budget), csv_format: format) }

      it "is refused even when it's an Account's default, which keeps it" do
        account = create(:budget_account, budget: budget, default_csv_format: format)

        expect { delete csv_format_path(format) }.not_to change(Budget::CsvFormat, :count)

        expect(account.reload.default_csv_format).to eq(format)
      end

      it "is refused, saying why on its edit page, and keeps the format" do
        expect { delete csv_format_path(format) }.not_to change(Budget::CsvFormat, :count)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(edit_csv_format_path(format))
        follow_redirect!
        assert_select "[role=alert]", text: "This CSV format can't be deleted because an Import used it."
      end

      it "can still be edited, which changes nothing that was imported" do
        transaction = create(:budget_bank_transaction, account: Budget::Import.sole.account, import: Budget::Import.sole, description: "Coffee shop")

        patch csv_format_path(format), params: { csv_format: { name: "CIBC Visa", date_order: "day_month_year" } }

        expect(format.reload).to have_attributes(name: "CIBC Visa", date_order: "day_month_year")
        expect(response).to redirect_to(csv_formats_path)
        expect(transaction.reload).to have_attributes(description: "Coffee shop", date: Date.new(2026, 9, 15), amount: -10)
      end

      it "can't be deleted by deleting its budget's other formats, which leave it alone" do
        other = create(:budget_csv_format, budget: budget, name: "Unused")

        expect { delete csv_format_path(other) }.to change(Budget::CsvFormat, :count).by(-1)

        expect(Budget::CsvFormat.exists?(format.id)).to be(true)
      end
    end
  end
end
