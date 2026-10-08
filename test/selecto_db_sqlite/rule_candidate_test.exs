defmodule SelectoDBSQLite.RuleCandidateTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.{Adapter, RuleCandidate}
  alias Selecto.Write.{Error, RecordState, RuleCandidateRequest}

  setup do
    {:ok, connection} = Adapter.connect(database: ":memory:")
    on_exit(fn -> Adapter.disconnect(connection) end)
    %{connection: connection}
  end

  test "projection observes native underflow and rolls back its private rows", %{
    connection: connection
  } do
    sql(
      connection,
      "CREATE TABLE items(id INTEGER PRIMARY KEY, quantity NUMERIC, reference TEXT COLLATE NOCASE DEFAULT 'COLLATE CUSTOM')"
    )

    sql(connection, "BEGIN")
    request = request(%{quantity: Decimal.new("1e-400"), reference: "ACTIVE"})

    assert {:ok, %RecordState{values: values, complete?: true, protection: :serializable}} =
             RuleCandidate.project(connection, request, [])

    assert Decimal.equal?(values["quantity"], Decimal.new(0))
    assert values["reference"] == "ACTIVE"
    assert rows(connection, "SELECT name FROM temp.sqlite_master") == []
    assert rows(connection, "SELECT * FROM items") == []
    sql(connection, "INSERT INTO items(quantity,reference) VALUES(2,'kept')")
    sql(connection, "COMMIT")
    assert rows(connection, "SELECT quantity FROM items") == [[2]]
  end

  test "booleans and large integral values keep their native scalar meaning", %{
    connection: connection
  } do
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY, enabled BOOLEAN, big BIGINT)")

    request = %{
      request(%{})
      | values: %{enabled: true, big: 9_007_199_254_740_993},
        field_types: %{enabled: :boolean, big: :bigint}
    }

    assert {:ok, %RecordState{values: %{"enabled" => true, "big" => 9_007_199_254_740_993}}} =
             RuleCandidate.project(connection, request, [])

    assert rows(connection, "SELECT name FROM temp.sqlite_master") == []
  end

  for shadow <- [
        "CREATE TEMP TABLE ITEMS(quantity NUMERIC,reference TEXT)",
        "CREATE TEMP VIEW ITEMS AS SELECT quantity,reference FROM main.items"
      ] do
    test "case-insensitive catalog shadow refuses projection: #{shadow}", %{
      connection: connection
    } do
      sql(
        connection,
        "CREATE TABLE items(id INTEGER PRIMARY KEY,quantity NUMERIC,reference TEXT)"
      )

      sql(connection, unquote(shadow))

      assert {:error, %Error{details: %{code: :required_data_rule_pending}}} =
               RuleCandidate.project(connection, request(%{quantity: Decimal.new(2)}), [])

      assert rows(connection, "SELECT * FROM main.items") == []
    end
  end

  test "unused generated columns and target triggers refuse before private projection", %{
    connection: connection
  } do
    sql(
      connection,
      "CREATE TABLE items(id INTEGER PRIMARY KEY,quantity NUMERIC,reference TEXT, derived NUMERIC GENERATED ALWAYS AS (quantity+1) VIRTUAL)"
    )

    assert {:error, %Error{details: %{code: :required_data_rule_pending}}} =
             RuleCandidate.project(connection, request(%{quantity: Decimal.new(2)}), [])

    sql(connection, "DROP TABLE items")
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY,quantity NUMERIC,reference TEXT)")

    sql(
      connection,
      "CREATE TRIGGER transform AFTER INSERT ON items BEGIN UPDATE items SET quantity=0; END"
    )

    assert {:error, %Error{details: %{code: :required_data_rule_pending}}} =
             RuleCandidate.project(connection, request(%{quantity: Decimal.new(2)}), [])

    assert rows(connection, "SELECT * FROM items") == []
    assert rows(connection, "SELECT name FROM temp.sqlite_master") == []
  end

  test "undeclared physical affinity and expression values refuse", %{connection: connection} do
    sql(connection, "CREATE TABLE items(id INTEGER PRIMARY KEY,quantity TEXT,reference TEXT)")

    assert {:error, %Error{details: %{code: :required_data_rule_pending}}} =
             RuleCandidate.project(connection, request(%{quantity: Decimal.new(2)}), [])

    assert {:error, %Error{details: %{code: :required_data_rule_pending}}} =
             RuleCandidate.project(connection, request(%{reference: {:raw, "upper('a')"}}), [])
  end

  defp request(values),
    do: %RuleCandidateRequest{
      operation: :insert,
      relation: "items",
      values: values,
      field_types: %{quantity: :decimal, reference: :string}
    }

  defp sql(connection, text) do
    {:ok, result} = Adapter.execute(connection, text, [], [])
    result
  end

  defp rows(connection, text), do: sql(connection, text).rows
end
