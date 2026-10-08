# Optional public Updato integration; load the selected core, Updato and SQLite
# adapter dependencies before running: elixir scripts/sqlite_owned_key_regression.exs
ExUnit.start()
{:ok, _} = Application.ensure_all_started(:selecto_updato)
{:ok, _} = Application.ensure_all_started(:selecto_db_sqlite)

defmodule SelectoDBSQLite.NativeOwnedKeyTest do
  use ExUnit.Case, async: true

  alias SelectoDBSQLite.Adapter
  alias SelectoUpdato.Error

  for mode <- [:update, :remove, :empty_sync, :insert, :hydrate, :child_rule] do
    test "public #{mode} refuses a child comparator that aliases another parent's key" do
      db = database("TEXT COLLATE BINARY", "TEXT COLLATE NOCASE", "A", "a", "A")
      op = operation(unquote(mode), "a")
      before = snapshot(db)
      changes = total_changes(db)

      assert {:error, %Error{type: :validation}} = execute(op, db)
      assert snapshot(db) == before
      # Rule projection writes only its rollback-only private TEMP row; SQLite's
      # total_changes counts those even after rollback. Non-rule refusals prove
      # that not even the root's business DML ran before catalog admission.
      if unquote(mode) not in [:hydrate, :child_rule], do: assert(total_changes(db) == changes)
    end
  end

  test "public graph refuses NUMERIC coercion of a distinct TEXT parent key" do
    db = database("TEXT COLLATE BINARY", "NUMERIC", "1", "01", 1)
    before = snapshot(db)
    changes = total_changes(db)

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             execute(operation(:update, "01"), db)

    assert snapshot(db) == before
    assert total_changes(db) == changes
  end

  for child_key <- [:owner_Ä, :"owner$key"] do
    test "public graph reads the actual comparison of #{child_key}" do
      key = unquote(child_key)

      db =
        database("TEXT COLLATE BINARY", "TEXT COLLATE NOCASE", "A", "a", "A",
          child_key: key,
          extra_column: ",owner_ä TEXT COLLATE BINARY"
        )

      before = sql(db, "SELECT id,#{key},reference FROM owned_children")
      changes = total_changes(db)
      op = operation(:update, "a", child_key: key)

      assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
               execute(op, db)

      assert sql(db, "SELECT id,#{key},reference FROM owned_children") == before
      assert parent_references(db) == [["A", "left"], ["a", "right"]]
      assert total_changes(db) == changes
    end
  end

  test "public prepared preview refuses mismatched ownership without candidate disclosure" do
    db = database("TEXT COLLATE BINARY", "TEXT COLLATE NOCASE", "A", "a", "A")
    before = snapshot(db)

    for mode <- [:update, :empty_sync, :hydrate, :child_rule] do
      assert {:error, %Error{type: :validation}} =
               SelectoUpdato.preview(operation(mode, "a"), selecto(db), context: %{tenant_id: 7})
    end

    assert snapshot(db) == before
  end

  test "catalog refusal preserves a caller-owned transaction and pending work" do
    db = database("TEXT COLLATE BINARY", "TEXT COLLATE NOCASE", "A", "a", "A")
    sql(db, "BEGIN")
    sql(db, "UPDATE owned_parents SET reference='pending' WHERE id='A'")
    before = snapshot(db)
    changes = total_changes(db)

    assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
             execute(operation(:remove, "a"), db)

    assert snapshot(db) == before
    assert total_changes(db) == changes
    sql(db, "ROLLBACK")
    assert parent_references(db) == [["A", "left"], ["a", "right"]]
  end

  test "equivalent TEXT comparators retain exact ownership and native collection rules" do
    db = database("TEXT COLLATE BINARY", "VARCHAR COLLATE BINARY", "A", "a", "A")
    before = snapshot(db)

    assert {:error, %Error{type: :cardinality_mismatch}} = execute(operation(:update, "a"), db)
    assert snapshot(db) == before

    assert {:ok, _} = execute(operation(:hydrate, "A"), db)
    assert children(db) == [[1, "A", "changed", 1]]
    assert parent_references(db) == [["A", "root-write"], ["a", "right"]]

    assert {:ok, _} = execute(operation(:empty_sync, "a"), db)
    assert children(db) == [[1, "A", "changed", 1]]
    assert {:ok, _} = execute(operation(:empty_sync, "A"), db)
    assert children(db) == []
  end

  test "equivalent NOCASE comparison preserves the actual returned owning key" do
    db = database("TEXT COLLATE NOCASE", "TEXT COLLATE NOCASE", "A", "B", "A")
    assert {:ok, _} = execute(operation(:child_rule, "a"), db)
    assert children(db) == [[1, "A", "changed", 1]]
    assert parent_references(db) == [["A", "root-write"], ["B", "right"]]
  end

  test "reverse collation mismatch and STRICT ANY refuse rather than infer ownership" do
    for {parent, child, left, right, owner} <- [
          {"TEXT COLLATE NOCASE", "TEXT COLLATE BINARY", "A", "B", "A"},
          {"TEXT COLLATE BINARY", "TEXT COLLATE RTRIM", "A", "A ", "A"},
          {"ANY", "ANY", "A", "a", "A"}
        ] do
      db = database(parent, child, left, right, owner, strict: parent == "ANY")
      before = snapshot(db)
      changes = total_changes(db)

      assert {:error, %Error{details: %{code: :owned_key_comparison_not_evaluable}}} =
               execute(operation(:update, left), db)

      assert snapshot(db) == before
      assert total_changes(db) == changes
    end
  end

  for {type, constraint} <- [
        {"TEXT", ""},
        {"TEXT COLLATE NOCASE", ",PRIMARY KEY(id COLLATE BINARY)"},
        {"TEXT COLLATE NOCASE", ",UNIQUE(id COLLATE BINARY)"}
      ] do
    test "public graph and both rule paths refuse an unproved unique parent: #{type}#{constraint}" do
      db =
        database(unquote(type), unquote(type), "A", "B", "A",
          parent_key_constraint: "",
          parent_extra: unquote(constraint),
          child_reference: ""
        )

      for mode <- [:update, :remove, :empty_sync, :hydrate, :child_rule] do
        before = snapshot(db)
        changes = total_changes(db)

        expected_code = refusal_code(mode)

        assert {:error, %Error{details: %{code: ^expected_code}}} =
                 execute(operation(mode, "A"), db)

        assert snapshot(db) == before
        if mode not in [:hydrate, :child_rule], do: assert(total_changes(db) == changes)
      end
    end
  end

  for reference <- [
        "REFERENCES other_parents(id)",
        "REFERENCES owned_parents(id) REFERENCES other_parents(id)",
        "REFERENCES other_parents(id) REFERENCES owned_parents(id)"
      ] do
    test "public ownership refuses every contradictory FK order: #{reference}" do
      db =
        database("TEXT", "TEXT", "A", "B", "A",
          other_parent: true,
          child_reference: unquote(reference)
        )

      for mode <- [:update, :remove, :empty_sync, :hydrate, :child_rule] do
        before = snapshot(db)
        changes = total_changes(db)

        expected_code = refusal_code(mode)

        assert {:error, %Error{details: %{code: ^expected_code}}} =
                 execute(operation(mode, "A"), db)

        assert snapshot(db) == before
        if mode not in [:hydrate, :child_rule], do: assert(total_changes(db) == changes)
      end

      sql(db, "BEGIN")
      sql(db, "UPDATE owned_parents SET reference='pending' WHERE id='B'")
      pending = snapshot(db)

      assert {:error, %Error{}} = execute(operation(:empty_sync, "A"), db)
      assert snapshot(db) == pending
      sql(db, "ROLLBACK")
      assert parent_references(db) == [["A", "left"], ["B", "right"]]
    end
  end

  for reference <- ["", "REFERENCES owned_parents"] do
    test "public native collection rules retain proven no-FK and implicit-PK ownership: #{reference}" do
      db = database("TEXT", "VARCHAR", "A", "B", "A", child_reference: unquote(reference))
      assert {:ok, _} = execute(operation(:hydrate, "A"), db)
      assert children(db) == [[1, "A", "changed", 1]]
      assert {:ok, _} = execute(operation(:empty_sync, "A"), db)
      assert children(db) == []
      assert parent_references(db) == [["A", "root-write"], ["B", "right"]]
    end
  end

  test "prepared preview refuses physical ownership without disclosing the wrong candidate" do
    db =
      database("TEXT", "TEXT", "A", "B", "A",
        other_parent: true,
        child_reference: "REFERENCES owned_parents(id) REFERENCES other_parents(id)"
      )

    before = snapshot(db)

    for mode <- [:update, :empty_sync, :hydrate, :child_rule] do
      expected_code = refusal_code(mode)

      assert {:error, %Error{details: %{code: ^expected_code}}} =
               SelectoUpdato.preview(operation(mode, "A"), selecto(db), context: %{tenant_id: 7})
    end

    assert snapshot(db) == before
  end

  # The public collection provider intentionally wraps unavailable storage
  # evidence. Individual record providers preserve the adapter's diagnostic.
  defp refusal_code(:hydrate), do: :candidate_state_unavailable
  defp refusal_code(_mode), do: :owned_key_comparison_not_evaluable

  defp database(parent_decl, child_decl, left, right, owner, opts \\ []) do
    {:ok, db} =
      Adapter.connect(database: ":memory:", temp_store: :memory, foreign_keys: true)

    on_exit(fn -> Adapter.disconnect(db) end)
    suffix = if opts[:strict], do: " STRICT", else: ""
    child_key = opts[:child_key] || :owner_id
    extra = opts[:extra_column] || ""
    parent_constraint = Keyword.get(opts, :parent_key_constraint, "PRIMARY KEY")
    parent_extra = opts[:parent_extra] || ""
    reference = Keyword.get(opts, :child_reference, "REFERENCES owned_parents(id)")

    if opts[:other_parent] do
      sql(db, "CREATE TABLE other_parents(id TEXT PRIMARY KEY)")
      sql(db, "INSERT INTO other_parents VALUES(?)", [owner])
    end

    sql(db, """
    CREATE TABLE owned_parents(id #{parent_decl} #{parent_constraint},tenant_id INTEGER,reference TEXT#{parent_extra})#{suffix}
    """)

    sql(db, """
    CREATE TABLE owned_children(id INTEGER PRIMARY KEY,#{child_key} #{child_decl} #{reference},
      tenant_id INTEGER,reference TEXT,quantity INTEGER#{extra})#{suffix}
    """)

    sql(db, "INSERT INTO owned_parents VALUES (?,7,'left'),(?,7,'right')", [left, right])

    sql(
      db,
      "INSERT INTO owned_children(id,#{child_key},tenant_id,reference,quantity) VALUES(1,?,7,'original',1)",
      [owner]
    )

    db
  end

  defp operation(mode, owner, opts \\ []) do
    payload =
      case mode do
        :remove -> %{mode: :delta, delete: [%{id: 1}]}
        :empty_sync -> []
        :insert -> %{mode: :delta, create: [%{reference: "new", quantity: 1}]}
        _ -> %{mode: :delta, update: [%{id: 1, reference: "changed"}]}
      end

    domain(mode)
    |> replace_child_key(opts[:child_key] || :owner_id)
    |> SelectoUpdato.new()
    |> SelectoUpdato.filter({:id, owner})
    |> SelectoUpdato.update(%{reference: "root-write", items: payload})
  end

  defp replace_child_key(value, :owner_id), do: value
  defp replace_child_key(:owner_id, key), do: key

  defp replace_child_key(value, key) when is_map(value),
    do:
      Map.new(value, fn {name, item} ->
        {replace_child_key(name, key), replace_child_key(item, key)}
      end)

  defp replace_child_key(value, key) when is_list(value),
    do: Enum.map(value, &replace_child_key(&1, key))

  defp replace_child_key(value, _key), do: value

  defp domain(mode) do
    child = %{
      name: "Owned children",
      source: %{
        source_table: "owned_children",
        primary_key: :id,
        fields: [:id, :tenant_id, :owner_id, :reference, :quantity],
        columns: %{
          id: %{type: :integer},
          tenant_id: %{type: :integer},
          owner_id: %{type: :string},
          reference: %{type: :string},
          quantity: %{type: :integer}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{
          insert: %{enabled: true},
          update: %{enabled: true},
          delete: %{enabled: true}
        },
        fields: %{
          reference: %{insertable: true, updatable: true},
          quantity: %{insertable: true, updatable: true}
        },
        scope: %{tenant: %{required: true, field: :tenant_id}}
      }
    }

    child =
      if mode == :child_rule,
        do: Map.put(child, :rules, rules(:positive, [:quantity], "number.gt", bound: "0")),
        else: child

    root = %{
      name: "Owned parents",
      source: %{
        source_table: "owned_parents",
        primary_key: :id,
        fields: [:id, :tenant_id, :reference],
        columns: %{
          id: %{type: :string},
          tenant_id: %{type: :integer},
          reference: %{type: :string}
        },
        associations: %{}
      },
      schemas: %{},
      joins: %{},
      writes: %{
        operations: %{update: %{enabled: true}},
        fields: %{reference: %{updatable: true}},
        scope: %{tenant: %{required: true, field: :tenant_id}},
        relationships: %{
          items: %{
            writable: true,
            cardinality: :many,
            ownership: :owned,
            allowed_ops: [:insert, :update, :delete],
            parent_key: :id,
            child_key: :owner_id,
            identity_fields: [:id],
            domain: child,
            write: %{modes: [:full_set, :delta]},
            strategy: :sync,
            delete_missing: true
          }
        }
      }
    }

    if mode == :hydrate,
      do: Map.put(root, :rules, rules(:exactly_one, [:items], "collection.count", exact: 1)),
      else: root
  end

  defp rules(id, path, operator, args) do
    %{
      schema: "selecto.data_rules.v1",
      definitions: %{id => %{version: 1, test: Map.new([{:op, operator} | args])}},
      normalizers: %{},
      bindings: %{
        id => %{
          subject: %{scope: :candidate, path: path},
          operations: [:update],
          rule: %{id: id, version: 1}
        }
      }
    }
  end

  defp selecto(db), do: %Selecto{adapter: Adapter, connection: db}
  defp execute(op, db), do: SelectoUpdato.execute(op, selecto(db), context: %{tenant_id: 7})

  defp sql(db, query, params \\ []) do
    {:ok, result} = Adapter.execute(db, query, params, [])
    result.rows
  end

  defp parent_references(db),
    do: sql(db, "SELECT id,reference FROM owned_parents ORDER BY id")

  defp children(db),
    do: sql(db, "SELECT id,owner_id,reference,quantity FROM owned_children ORDER BY id")

  defp snapshot(db), do: {parent_references(db), children(db)}
  defp total_changes(db), do: sql(db, "SELECT total_changes()")
end
