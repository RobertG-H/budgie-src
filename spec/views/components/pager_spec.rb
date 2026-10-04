require "rails_helper"

RSpec.describe "components/_pager", type: :view do
  def render_pager(page:, more:)
    render partial: "components/pager", locals: { page: page, more: more, path: ->(number) { "/accounts/7?page=#{number}" } }
  end

  it "is nothing when there's only one page" do
    render_pager page: 1, more: false

    assert_select "nav", count: 0
  end

  it "links to the next, older, page when there is one, and not back from the first" do
    render_pager page: 1, more: true

    assert_select "nav[aria-label=Pages] a[rel=next][href='/accounts/7?page=2']", text: "Older"
    assert_select "nav[aria-label=Pages] a[rel=prev]", count: 0
  end

  it "links both ways from the middle" do
    render_pager page: 2, more: true

    assert_select "a[rel=next][href='/accounts/7?page=3']", text: "Older"
    assert_select "a[rel=prev][href='/accounts/7?page=1']", text: "Newer"
  end

  it "links back from the last page, to the newer one" do
    render_pager page: 3, more: false

    assert_select "a[rel=next]", count: 0
    assert_select "a[rel=prev][href='/accounts/7?page=2']", text: "Newer"
  end
end
