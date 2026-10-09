defmodule SelectoDBSQLite.StorageAuthorityTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.{Adapter, InsertAdmission}
  alias Selecto.Write.{Command, RecordRequest, RecordState}

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)
    assert sql(db, "PRAGMA temp_store") == [[2]]
    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_, _, file] -> file == "" end)
    %{db: db}
  end

  for schema <- ["main", "temp"] do
    test "#{schema} SQL PRAGMA tables cannot replace native storage facts", %{db: db} do
      sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,subject TEXT)")
      spoof(db, unquote(schema), "items", "view", 1)
      assert {:ok, columns} = InsertAdmission.storage_schema(db, "ItEmS", [])
      assert columns["id"].rowid_alias
      assert columns["id"].without_rowid == 0
      assert {:ok, %{affected_rows: 1}} = Adapter.execute_write_unsafe(db, insert())
      assert sql(db, "SELECT id,subject FROM main.items") == [[1, "active"]]

      sql(db, "CREATE TEMP TABLE ITEMS(id INTEGER PRIMARY KEY,subject TEXT)")
      before = sql(db, "SELECT total_changes()")

      assert {:error, %{details: %{code: :query_rule_not_evaluable}}} =
               Adapter.execute_write_unsafe(db, insert())

      assert sql(db, "SELECT total_changes()") == before
      assert sql(db, "SELECT id,subject FROM main.items") == [[1, "active"]]
      assert sql(db, "SELECT id,subject FROM temp.ITEMS") == []
    end
  end

  test "native primary indexes distinguish DESC storage from rowid aliases", %{db: db} do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY DESC,subject TEXT)")
    spoof(db, "temp", "items", "table", 0)
    assert {:ok, columns} = InsertAdmission.storage_schema(db, "items", [])
    refute columns["id"].rowid_alias
    sql(db, "INSERT INTO items(subject) VALUES('a'),('b')")
    assert sql(db, "SELECT rowid,id FROM items") == [[1, nil], [2, nil]]
    sql(db, "DROP TABLE items")
    sql(db, "CREATE TABLE items(id INTEGER,subject TEXT,PRIMARY KEY(id DESC))")
    assert {:ok, columns} = InsertAdmission.storage_schema(db, "items", [])
    assert columns["id"].rowid_alias
    sql(db, "INSERT INTO items(subject) VALUES('a'),('b')")
    assert sql(db, "SELECT rowid,id FROM items") == [[1, 1], [2, 2]]
  end

  test "physical snapshot witnesses use actual WITHOUT ROWID facts", %{db: db} do
    sql(db, "CREATE TABLE items(id INTEGER PRIMARY KEY,subject TEXT) WITHOUT ROWID")
    sql(db, "INSERT INTO items VALUES(1,'kept')")
    spoof(db, "temp", "items", "table", 0)
    assert {:ok, columns} = InsertAdmission.storage_schema(db, "items", [])
    assert columns["id"].without_rowid == 1
    refute columns["id"].rowid_alias

    request = %RecordRequest{
      operation: :update,
      relation: "items",
      predicate: {:eq, {:field, "id"}, {:literal, 1}},
      fields: ["id", "subject"]
    }

    assert {:ok,
            %RecordState{
              complete?: true,
              protection: :locked,
              values: %{"id" => 1, "subject" => "kept"}
            }} =
             Adapter.load_record_state(db, request)

    assert sql(db, "SELECT id,subject FROM items") == [[1, "kept"]]
  end

  test "spoofed ordinary table facts cannot admit an FTS5 shadow", %{db: db} do
    sql(db, "CREATE VIRTUAL TABLE documents USING fts5(body)")
    spoof(db, "temp", "documents_data", "table", 0)

    assert {:error, %{details: %{code: :query_rule_not_evaluable}}} =
             InsertAdmission.storage_schema(db, "documents_data", [])
  end

  defp spoof(db, schema, name, type, wr) do
    sql(
      db,
      "CREATE TABLE #{schema}.pragma_table_list(schema TEXT,name TEXT,type TEXT,ncol INTEGER,wr INTEGER,strict INTEGER)"
    )

    assert {:ok, _} =
             Adapter.execute(
               db,
               "INSERT INTO #{schema}.pragma_table_list VALUES('main',?,?,2,?,0)",
               [name, type, wr],
               []
             )

    sql(
      db,
      "CREATE TABLE #{schema}.pragma_index_list(seq INTEGER,name TEXT,\"unique\" INTEGER,origin TEXT,partial INTEGER)"
    )

    sql(db, "INSERT INTO #{schema}.pragma_index_list VALUES(0,'forged',1,'c',0)")
  end

  defp insert do
    {:ok, command} =
      Command.new(%{
        operation: :insert,
        relation: "items",
        assignments: [
          %{field: "id", value: {:literal, 1}},
          %{field: "subject", value: {:literal, "active"}}
        ],
        returning: :none,
        required_capabilities: [:typed_insert_admission],
        metadata: %{
          field_types: %{id: :integer, subject: :string},
          insert_admission: %{
            storage_backend: :sqlite,
            predicate: {:eq, {:field, "subject"}, {:literal, "active"}}
          }
        }
      })

    command
  end

  defp sql(db, text) do
    assert {:ok, %{rows: rows}} = Adapter.execute(db, text, [], [])
    rows
  end
end
