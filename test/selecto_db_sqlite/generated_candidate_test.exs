defmodule SelectoDBSQLite.GeneratedCandidateTest do
  use ExUnit.Case, async: true

  alias Selecto.Write.{RecordState, RuleCandidateRequest}
  alias SelectoDBSQLite.{Adapter, InsertAdmission, RuleCandidate}

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  for {ddl, alias?} <- [
        {"id INTEGER PRIMARY KEY", true},
        {"id INTEGER PRIMARY KEY AUTOINCREMENT", true},
        {"id INTEGER PRIMARY KEY DEFAULT 7", true},
        {"id INTEGER PRIMARY KEY DESC", false},
        {"id INT PRIMARY KEY", false},
        {"id INTEGER, PRIMARY KEY(id DESC)", true},
        {"id INTEGER PRIMARY KEY) WITHOUT ROWID", false}
      ] do
    test "catalog identifies actual rowid alias: #{ddl}", %{connection: connection} do
      definition = unquote(ddl)

      statement =
        if String.ends_with?(definition, "WITHOUT ROWID"),
          do: "CREATE TABLE items(" <> definition,
          else: "CREATE TABLE items(" <> definition <> ")"

      sql(connection, statement)
      assert {:ok, schema} = InsertAdmission.storage_schema(connection, "items", [])
      assert schema["id"].rowid_alias == unquote(alias?)
    end
  end

  test "omitted and NULL aliases refuse before private projection when consumed", %{
    connection: connection
  } do
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY DEFAULT 7,name TEXT)")
    before = sql(connection, "SELECT total_changes()").rows

    for values <- [%{name: "new"}, %{id: nil, name: "new"}] do
      assert {:error, %{details: %{code: :required_data_rule_pending}}} =
               RuleCandidate.project(connection, request(values, ["id"]), [])
    end

    assert sql(connection, "SELECT total_changes()").rows == before
    assert sql(connection, "SELECT name FROM temp.sqlite_master").rows == []
  end

  test "unconsumed NULL alias is retained as intent without projecting a fake rowid", %{
    connection: connection
  } do
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT)")

    assert {:ok, %RecordState{values: %{"id" => nil, "name" => "new"}}} =
             RuleCandidate.project(connection, request(%{id: nil, name: "new"}, ["name"]), [])

    assert sql(connection, "SELECT * FROM items").rows == []
    assert sql(connection, "SELECT name FROM temp.sqlite_master").rows == []
  end

  test "omitted nullable storage is known NULL but defaults remain explicitly unproved", %{
    connection: connection
  } do
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT)")

    assert {:ok, %RecordState{values: %{"id" => 7, "name" => nil}}} =
             RuleCandidate.project(connection, request(%{id: 7}, ["name"]), [])

    sql(connection, "DROP TABLE items")
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT DEFAULT 'known')")
    before = sql(connection, "SELECT total_changes()").rows

    assert {:error, %{details: %{code: :required_data_rule_pending}}} =
             RuleCandidate.project(connection, request(%{id: 7}, ["name"]), [])

    assert sql(connection, "SELECT total_changes()").rows == before
  end

  defp request(values, dependencies),
    do: %RuleCandidateRequest{
      operation: :insert,
      relation: "items",
      values: values,
      field_types: %{id: :integer, name: :string},
      context: %{selecto_rule_candidate_dependencies: dependencies}
    }

  defp sql(connection, query) do
    {:ok, result} = Adapter.execute(connection, query, [], [])
    result
  end
end
