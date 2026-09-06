defmodule SelectoDBSQLite.DocumentSourceProfileTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, ShapeRelease}
  alias Selecto.Query.Plan

  test "direct compilation rejects unimplemented namespace and JSON number policies" do
    for {key, value} <- [{"namespace", ["bucket", "scope"]}, {"numeric_semantics", "json_number"}] do
      {:ok, draft} = ShapeRelease.new(put_in(Fixtures.shape(), ["source", key], value))
      {:ok, release} = ShapeRelease.approve(draft, approved_by: "profile-test")

      {:ok, plan} =
        Plan.new(release, "work_orders", %{}, trusted_context: %{tenant_id: "tenant-a"})

      assert {:error, _} = SelectoDBSQLite.DocumentQueryAdapter.compile_query(nil, plan, [])
    end
  end
end
