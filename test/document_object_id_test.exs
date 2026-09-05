defmodule SelectoDBSQLite.DocumentObjectIdTest do
  use ExUnit.Case, async: true
  alias Selecto.Document.{Fixtures, ObjectId}
  alias Selecto.Query.{CapabilityProfile, Plan, Runtime}
  alias SelectoDBSQLite.{Adapter, DocumentQueryAdapter}

  test "native ObjectId releases fail before SQL even when the field is unselected" do
    {:ok, db} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)
    # Deliberately no source table: none of these valid plans may reach source SQL.
    release = Fixtures.object_id_release()
    {:ok, identity} = ObjectId.new("507f1f77bcf86cd799439011")
    {:ok, profile} = DocumentQueryAdapter.capabilities(db, %{})
    refute "document.object_id" in profile.enabled
    refute "document.object_id" in profile.certified

    queries = [
      {"work_orders", %{"select" => ["state"]}},
      {"work_orders", %{"aggregate" => [%{"op" => "count", "as" => "total"}]}},
      {"work_order_schedule", %{"select" => ["timezone"], "parent_identity" => identity}}
    ]

    for {relation, query} <- queries do
      assert {:ok, plan} =
               Plan.new(release, relation, query, trusted_context: %{tenant_id: "tenant-a"})

      assert "document.object_id" in plan.required_capabilities
      assert {:error, _} = CapabilityProfile.preflight(profile, plan)
      assert {:error, _} = Runtime.compile(plan, DocumentQueryAdapter, db)
      assert {:error, _} = Runtime.execute(plan, DocumentQueryAdapter, db)
      assert {:error, _} = DocumentQueryAdapter.compile_query(db, plan, [])
    end
  end
end
