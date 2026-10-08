require "rails_helper"

# The builder asks for this each time a choice changes, sending the whole form with the sample file in it. The sample is read
# for the request and never kept.
RSpec.describe "CSV format previews", type: :request do
  let(:budget) { create(:budget, currency: "CAD") }

  before { sign_in_as budget.user }

  let(:turbo_stream) { { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" } }

  # What the form sends for the signed sample file: a header to skip, the date first, then the description and the amount.
  let(:format_params) do
    { name: "", rows_to_skip: "1", date_column: "1", date_order: "year_month_day", description_columns: "2",
      amount_style: "signed", amount_column: "3", invert_sign: "0" }
  end

  def upload(name, type: "text/csv")
    Rack::Test::UploadedFile.new(file_fixture(name), type)
  end

  # A sample made of the text, as if it were a file.
  def upload_text(text)
    Rack::Test::UploadedFile.new(StringIO.new(text), "text/csv", original_filename: "sample.csv")
  end

  def preview(sample: "signed-sample.csv", headers: turbo_stream, **changes)
    params = format_params.merge(changes.except(:csv_format_id))
    params = params.merge(sample: upload(sample)) if sample
    post csv_format_preview_path, params: { csv_format: params, csv_format_id: changes[:csv_format_id] }.compact, headers: headers
  end

  # What a person reads in the preview, a row to a line.
  def previewed_rows
    css_select("turbo-stream[target=csv-format-preview] tbody tr").map { |row| row.css("th, td").map { |cell| cell.text.squish }.join(" | ") }
  end

  it "answers with Turbo Streams that replace the grid and the preview, and nothing else" do
    preview

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(css_select("turbo-stream").map { |stream| [ stream["action"], stream["target"] ] })
      .to eq([ [ "replace", "csv-format-grid" ], [ "replace", "csv-format-preview" ] ])
  end

  describe "the grid" do
    it "numbers the sample's columns, and its rows by line, saying which are skipped" do
      preview

      assert_select "turbo-stream[target=csv-format-grid] template" do
        assert_select "thead th", text: "Line"
        assert_select "thead th[scope=col]", text: "1"
        assert_select "thead th[scope=col]", text: "3"
        assert_select "thead th[scope=col]", text: "4", count: 0
        assert_select "tbody tr", count: 7
        assert_select "tbody tr:first-child th", text: /1\s+Skipped/
        assert_select "tbody tr:first-child td", text: "Description"
        assert_select "tbody tr:nth-child(2) th", text: "2"
        assert_select "tbody tr:nth-child(2) th .badge", count: 0
        assert_select "tbody tr:nth-child(3) td", text: "Loblaws"
      end
    end

    it "takes the column count from the sample, whatever the form says it was" do
      preview column_count: "99"

      assert_select "turbo-stream[target=csv-format-grid] input[type=hidden][name='csv_format[column_count]'][value='3']"
    end

    it "takes the column count from the first row the format reads, so rows to skip are what decide it" do
      post csv_format_preview_path, params: { csv_format: format_params.merge(rows_to_skip: "2", sample: upload_text("Account: Chequing\nDate,Description,Amount,Extra\n2026-09-01,Paycheck,10.00,x\n")) }, headers: turbo_stream

      assert_select "turbo-stream[target=csv-format-grid] input[name='csv_format[column_count]'][value='4']"
    end

    it "shows only the first rows of a longer file" do
      post csv_format_preview_path, params: { csv_format: format_params.merge(rows_to_skip: "0", sample: upload_text("2026-09-01,Coffee shop,-1.00\n" * 30)) }, headers: turbo_stream

      assert_select "turbo-stream[target=csv-format-grid] tbody tr", count: Budget::CsvFormat::Sample::GRID_ROWS
    end

    it "says why a sample can't be read, instead of showing a grid" do
      post csv_format_preview_path, params: { csv_format: format_params.merge(sample: upload_text("2026-09-01,Caf\xE9,-5.00\n".b)) }, headers: turbo_stream

      assert_select "turbo-stream[target=csv-format-grid] [role=alert]", text: "The file isn't UTF-8 text. Save it again as CSV in UTF-8 and try again."
      assert_select "turbo-stream[target=csv-format-grid] table", count: 0
      assert_select "turbo-stream[target=csv-format-preview]", text: /The sample can't be read/
    end

    it "keeps the column count the form had when there's no sample, so an edit can still be saved" do
      preview sample: nil, column_count: "3"

      assert_select "turbo-stream[target=csv-format-grid] input[name='csv_format[column_count]'][value='3']"
      assert_select "turbo-stream[target=csv-format-grid]", text: /Choose a sample file to see its first rows/
    end

    it "doesn't take something that isn't a file for one" do
      post csv_format_preview_path, params: { csv_format: format_params.merge(sample: "2026-09-01,Coffee shop,-1.00") }, headers: turbo_stream

      assert_select "turbo-stream[target=csv-format-grid] table", count: 0
      assert_select "turbo-stream[target=csv-format-preview]", text: /Choose a sample file to see how its rows read/
    end
  end

  describe "the preview" do
    it "shows the first rows as they'll be read, with the date spelled out and money in and money out told apart in words" do
      preview

      expect(previewed_rows).to eq([
        "2 | Sep 1, 2026 | Paycheck | $2,800.00 Money in",
        "3 | Sep 2, 2026 | Loblaws | -$82.45 Money out",
        "4 | Sep 3, 2026 | Hydro | -$65.50 Money out",
        "5 | Sep 5, 2026 | Coffee shop | -$4.25 Money out",
        "6 | Sep 9, 2026 | Hydro rebate | $12.25 Money in"
      ])
      assert_select "turbo-stream[target=csv-format-preview] .text-error", text: "-$82.45"
      assert_select "turbo-stream[target=csv-format-preview]", text: /5 rows\. 1 row of 0 would be skipped\./
    end

    it "shows a row the bank gave no description as No description, and doesn't refuse it" do
      post csv_format_preview_path, params: { csv_format: format_params.merge(sample: upload_text("Date,Description,Amount\n2026-09-01,Paycheck,2800.00\n2026-09-02,,-250.00\n")) }, headers: turbo_stream

      expect(previewed_rows).to eq([ "2 | Sep 1, 2026 | Paycheck | $2,800.00 Money in", "3 | Sep 2, 2026 | No description | -$250.00 Money out" ])
      assert_select "turbo-stream[target=csv-format-preview]", text: /2 rows\./
    end

    it "reads separate money in and money out columns, with the same result" do
      preview sample: "in-and-out-sample.csv", amount_style: "in_and_out", amount_column: "", money_out_column: "3", money_in_column: "4"

      expect(previewed_rows.first(2)).to eq([ "2 | Sep 1, 2026 | Paycheck | $2,800.00 Money in", "3 | Sep 2, 2026 | Loblaws | -$82.45 Money out" ])
    end

    it "reads an unsigned amount with a direction, with the same result" do
      preview sample: "direction-sample.csv", amount_style: "direction", direction_column: "4", money_in_value: "Credit"

      expect(previewed_rows.first(2)).to eq([ "2 | Sep 1, 2026 | Paycheck | $2,800.00 Money in", "3 | Sep 2, 2026 | Loblaws | -$82.45 Money out" ])
    end

    it "flips money in and money out when the sign is inverted" do
      preview invert_sign: "1"

      expect(previewed_rows.first(2)).to eq([ "2 | Sep 1, 2026 | Paycheck | -$2,800.00 Money out", "3 | Sep 2, 2026 | Loblaws | $82.45 Money in" ])
    end

    it "says how many rows there are when it shows only the first few" do
      post csv_format_preview_path, params: { csv_format: format_params.merge(rows_to_skip: "0", sample: upload_text("2026-09-01,Coffee shop,-1.00\n" * 8)) }, headers: turbo_stream

      expect(previewed_rows.size).to eq(5)
      assert_select "turbo-stream[target=csv-format-preview]", text: /The first 5 of 8 rows\./
    end

    it "shows the first row it would refuse, and why, instead of any rows" do
      post csv_format_preview_path, params: { csv_format: format_params.merge(sample: upload_text("Date,Description,Amount\n2026-09-01,Paycheck,10.00\n13/45/2026,Loblaws,-5.00\n2026-09-03,Hydro,abc\n")) }, headers: turbo_stream

      expect(previewed_rows).to be_empty
      assert_select "turbo-stream[target=csv-format-preview] [role=alert]",
        text: "This file would be refused. Line 3: the date \"13/45/2026\" isn't a date in year, month, day order."
    end

    it "finds a row to refuse that's past the ones it would show" do
      rows = "2026-09-01,Coffee shop,-1.00\n" * 20 + "2026-09-01,Coffee shop,1.005\n"
      post csv_format_preview_path, params: { csv_format: format_params.merge(rows_to_skip: "0", sample: upload_text(rows)) }, headers: turbo_stream

      assert_select "turbo-stream[target=csv-format-preview] [role=alert]", text: /Line 21: the amount "1.005" has more than 2 decimal places\./
    end

    it "says what's still to choose, when the format can't read a row yet, other than a name" do
      preview date_column: "", date_order: "", amount_column: "", description_columns: ""

      expect(previewed_rows).to be_empty
      assert_select "turbo-stream[target=csv-format-preview] li", text: "Date column can't be blank"
      assert_select "turbo-stream[target=csv-format-preview] li", text: "Date order must be chosen"
      assert_select "turbo-stream[target=csv-format-preview] li", text: "Description columns can't be blank"
      assert_select "turbo-stream[target=csv-format-preview] li", text: "Amount column can't be blank"
      assert_select "turbo-stream[target=csv-format-preview] li", text: /Name/, count: 0
    end

    it "says to choose a sample, when there isn't one" do
      preview sample: nil

      assert_select "turbo-stream[target=csv-format-preview]", text: /Choose a sample file to see how its rows read/
    end

    it "doesn't mind a number of rows to skip that isn't a number of rows" do
      [ "-5", "abc", "", "99999999" ].each do |rows|
        preview rows_to_skip: rows

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "choosing the date order" do
    def date_order_stream
      css_select("turbo-stream[target=csv-format-date-order]")
    end

    it "chooses it from the sample when it's still to choose, and replaces the field with it chosen" do
      preview date_order: ""

      expect(date_order_stream.size).to eq(1)
      assert_select "turbo-stream[target=csv-format-date-order] select[name='csv_format[date_order]'] option[selected][value=year_month_day]"
      expect(previewed_rows.first).to eq("2 | Sep 1, 2026 | Paycheck | $2,800.00 Money in")
    end

    it "chooses day first when a day is over 12, as far down the file as it is" do
      rows = "Date,Description,Amount\n" + "04/09/2026,Coffee shop,-1.00\n" * 30 + "13/09/2026,Coffee shop,-1.00\n"
      post csv_format_preview_path, params: { csv_format: format_params.merge(date_order: "", sample: upload_text(rows)) }, headers: turbo_stream

      assert_select "turbo-stream[target=csv-format-date-order] option[selected][value=day_month_year]"
      expect(previewed_rows.first).to eq("2 | Sep 4, 2026 | Coffee shop | -$1.00 Money out")
    end

    it "leaves it to choose when the sample's dates read more than one way" do
      rows = "Date,Description,Amount\n04/09/2026,Coffee shop,-1.00\n05/09/2026,Hydro,-2.00\n"
      post csv_format_preview_path, params: { csv_format: format_params.merge(date_order: "", sample: upload_text(rows)) }, headers: turbo_stream

      expect(date_order_stream).to be_empty
      assert_select "turbo-stream[target=csv-format-preview] li", text: "Date order must be chosen"
    end

    it "never changes one that's chosen, even when the sample's dates don't read in it" do
      preview date_order: "month_day_year"

      expect(date_order_stream).to be_empty
      assert_select "turbo-stream[target=csv-format-preview] [role=alert]", text: /isn't a date in month, day, year order/
    end
  end

  describe "for a format that's being edited" do
    let!(:format) { create(:budget_csv_format, budget: budget, name: "CIBC", date_order: "month_day_year") }

    it "reads the sample with the choices that were sent, and doesn't save them" do
      preview csv_format_id: format.id, rows_to_skip: "1", date_order: "year_month_day"

      expect(response).to have_http_status(:ok)
      expect(previewed_rows.first).to eq("2 | Sep 1, 2026 | Paycheck | $2,800.00 Money in")
      expect(format.reload).to have_attributes(date_order: "month_day_year", rows_to_skip: 0)
    end

    it "is not found for another user's format" do
      others = create(:budget_csv_format, name: "Someone else's")

      preview csv_format_id: others.id

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "without JavaScript" do
    it "answers with the whole builder, with how the sample reads in it" do
      preview headers: {}

      expect(response).to have_http_status(:ok)
      assert_select "h1", text: "New CSV format"
      assert_select "form[action='#{csv_formats_path}'] #csv-format-grid th[scope=col]", text: "3"
      assert_select "form #csv-format-preview tbody tr", count: 5
      assert_select "input[name='csv_format[rows_to_skip]'][value='1']"
    end

    it "answers with the edit page for a format that's being edited" do
      format = create(:budget_csv_format, budget: budget, name: "CIBC")

      preview headers: {}, csv_format_id: format.id

      assert_select "h1", text: "Edit CSV format"
      assert_select "form input[name=_method][value=patch]"
    end
  end

  it "creates and changes nothing, and keeps nothing of the sample" do
    other_formats = create_list(:budget_csv_format, 2, budget: budget)

    expect { preview }.not_to change { Budget::CsvFormat.order(:id).pluck(:id, :updated_at) }
    expect(Budget::CsvFormat.where(id: other_formats.map(&:id)).count).to eq(2)
  end

  it "requires sign-in" do
    delete session_path

    preview

    expect(response).to redirect_to(sign_in_path)
  end

  it "is a bad request without the form" do
    post csv_format_preview_path, headers: turbo_stream

    expect(response).to have_http_status(:bad_request)
  end
end
