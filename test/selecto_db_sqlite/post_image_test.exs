defmodule SelectoDBSQLite.PostImageTest do
  use ExUnit.Case, async: false

  # TW-09 post-image: a guarded write's rows are re-read by key under the
  # trusted scope after the statement and its triggers have run.

  alias SelectoDBSQLite.Adapter
  alias Selecto.Write.{Command, Error}

  setup do
    {:ok, c} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(c) end)

    exec!(
      c,
      "CREATE TABLE tw (id INTEGER PRIMARY KEY, org_key TEXT, site TEXT, name TEXT, touched INTEGER DEFAULT 0)"
    )

    exec!(c, "INSERT INTO tw (id, org_key, site, name) VALUES (1, 'T1', 'S1', 'a')")
    %{connection: c}
  end

  defp exec!(c, sql), do: {:ok, _} = Adapter.execute(c, sql, [], [])

  defp update(assignments, scope, relation \\ "tw", key \\ ["id"]) do
    {:ok, command} =
      Command.new(%{
        operation: :update,
        relation: relation,
        predicate: {:and, [{:eq, {:field, "id"}, {:literal, 1}}, scope]},
        assignments: Enum.map(assignments, fn {f, v} -> %{field: f, value: {:literal, v}} end),
        expected_cardinality: {:exactly, 1},
        metadata: %{post_image: %{predicate: scope, key: key}}
      })

    command
  end

  defp insert(values, guard) do
    {:ok, command} =
      Command.new(%{
        operation: :insert,
        relation: "tw",
        assignments: Enum.map(values, fn {f, v} -> %{field: f, value: {:literal, v}} end),
        returning: [:id],
        metadata: %{post_image: %{predicate: guard, key: ["id"]}}
      })

    command
  end

  defp site(value), do: {:eq, {:field, "site"}, {:literal, value}}
  defp tenant(value), do: {:eq, {:field, "org_key"}, {:literal, value}}

  defp stored(c, relation \\ "main.tw") do
    {:ok, %{rows: rows}} =
      Adapter.execute(c, "SELECT id, org_key, site, name FROM #{relation} ORDER BY id", [], [])

    rows
  end

  defp violation?(result),
    do: match?({:error, %Error{details: %{code: :query_rule_violation}}}, result)

  defp not_evaluable?(result),
    do: match?({:error, %Error{details: %{code: :query_rule_not_evaluable}}}, result)

  test "an update that assigns the scoped column rolls back", %{connection: c} do
    assert violation?(Adapter.execute_write_unsafe(c, update([{"site", "S9"}], site("S1")), []))
    assert stored(c) == [[1, "T1", "S1", "a"]]
  end

  # Triggers and temp relations are already outside the prepared write plan
  # (PreparedWriteSafety); the post-image never makes them writable.
  test "an AFTER trigger that moves the row out of the scope is refused", %{connection: c} do
    exec!(
      c,
      "CREATE TRIGGER tw_a AFTER UPDATE ON tw BEGIN UPDATE tw SET org_key = lower(org_key) WHERE id = NEW.id; END"
    )

    exec!(
      c,
      "CREATE TRIGGER tw_ai AFTER INSERT ON tw BEGIN UPDATE tw SET org_key = lower(org_key) WHERE id = NEW.id; END"
    )

    refute match?(
             {:ok, _},
             Adapter.execute_write_unsafe(c, update([{"name", "u"}], tenant("T1")), [])
           )

    refute match?(
             {:ok, _},
             Adapter.execute_write_unsafe(
               c,
               insert([{"id", 2}, {"org_key", "T1"}, {"site", "S1"}], tenant("T1")),
               []
             )
           )

    assert stored(c) == [[1, "T1", "S1", "a"]]
  end

  test "a temp table shadowing main is refused", %{connection: c} do
    exec!(
      c,
      "CREATE TEMP TABLE tw (id INTEGER PRIMARY KEY, org_key TEXT, site TEXT, name TEXT)"
    )

    exec!(c, "INSERT INTO temp.tw VALUES (1, 'T1', 'S1', 'a')")

    exec!(
      c,
      "CREATE TEMP TRIGGER tw_t AFTER UPDATE ON temp.tw BEGIN UPDATE temp.tw SET site = 'S9' WHERE id = NEW.id; END"
    )

    # The main table still holds a matching row with the same key.
    refute match?(
             {:ok, _},
             Adapter.execute_write_unsafe(c, update([{"name", "u"}], site("S1")), [])
           )

    assert stored(c, "temp.tw") == [[1, "T1", "S1", "a"]]
    assert stored(c) == [[1, "T1", "S1", "a"]]
  end

  test "a view and a table without a usable key are refused", %{connection: c} do
    exec!(c, "CREATE VIEW tw_v AS SELECT * FROM tw")

    exec!(
      c,
      "CREATE TRIGGER tw_v_u INSTEAD OF UPDATE ON tw_v BEGIN UPDATE tw SET name = NEW.name WHERE id = OLD.id; END"
    )

    refute match?(
             {:ok, _},
             Adapter.execute_write_unsafe(c, update([{"name", "u"}], site("S1"), "tw_v"), [])
           )

    exec!(c, "CREATE TABLE dk (id INTEGER NOT NULL, site TEXT, name TEXT)")
    exec!(c, "CREATE INDEX dk_id ON dk (id)")
    exec!(c, "INSERT INTO dk VALUES (1, 'S1', 'x'), (1, 'S2', 'y')")

    assert not_evaluable?(
             Adapter.execute_write_unsafe(c, update([{"name", "u"}], site("S1"), "dk"), [])
           )

    # A user column named rowid shadows the real rowid.
    exec!(c, "CREATE TABLE sr (\"rowid\" TEXT, id INTEGER, site TEXT, name TEXT)")
    exec!(c, "INSERT INTO sr VALUES ('k', 1, 'S1', 'x')")

    assert not_evaluable?(
             Adapter.execute_write_unsafe(
               c,
               update([{"name", "u"}], site("S1"), "sr", ["rowid"]),
               []
             )
           )

    assert stored(c) == [[1, "T1", "S1", "a"]]
  end

  test "in-scope writes apply; results keep their shape", %{connection: c} do
    assert {:ok, %{affected_rows: 1, rows: []}} =
             Adapter.execute_write_unsafe(c, update([{"name", "u"}], site("S1")), [])

    assert {:ok, %{affected_rows: 1, rows: [%{"id" => 2}]}} =
             Adapter.execute_write_unsafe(
               c,
               insert([{"id", 2}, {"org_key", "T1"}, {"site", "S1"}, {"name", "n"}], site("S1")),
               []
             )

    assert violation?(
             Adapter.execute_write_unsafe(
               c,
               insert([{"id", 3}, {"org_key", "T1"}, {"site", "S2"}, {"name", "n"}], site("S1")),
               []
             )
           )

    assert stored(c) == [[1, "T1", "S1", "u"], [2, "T1", "S1", "n"]]
  end
end
