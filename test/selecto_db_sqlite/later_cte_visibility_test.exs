defmodule SelectoDBSQLite.LaterCteVisibilityTest do
  # SQLite shows a CTE body every CTE of its WITH, the ones defined after it
  # included, with or without RECURSIVE. Selecto refuses a list named like a
  # relation the statement reads anywhere, so such a body never reads the CTE.
  use ExUnit.Case, async: false

  alias SelectoDBSQLite.Adapter

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)
    on_exit(fn -> Adapter.disconnect(db) end)

    for sql <- [
          "CREATE TABLE p (id INT PRIMARY KEY, name VARCHAR(20))",
          "CREATE TABLE lk (product_id INT, label VARCHAR(20))",
          "INSERT INTO p VALUES (1, 'a'), (2, 'b')",
          "INSERT INTO lk VALUES (1, 'TBL-LK')"
        ],
        do: {:ok, _} = Adapter.execute(db, sql, [], [])

    %{db: db}
  end

  @label %{"label" => %{type: :string}}

  defp p(db) do
    %{
      name: "p",
      schemas: %{},
      joins: %{},
      source: %{
        source_table: "p",
        primary_key: :id,
        fields: [:id, :name],
        redact_fields: [],
        columns: %{id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      }
    }
    |> Selecto.configure(db, adapter: Adapter, validate: false)
  end

  defp lk(db) do
    Selecto.Advanced.CTE.create_cte(
      "lk",
      fn -> p(db) |> Selecto.select(["id", "name"]) end,
      columns: ["product_id", "label"]
    )
  end

  defp body(db, source) do
    fn ->
      p(db)
      |> Selecto.join(:lkj,
        source: source,
        type: :left,
        owner_key: :id,
        related_key: :product_id,
        fields: @label
      )
      |> Selecto.select(["id", "lkj.label"])
    end
  end

  # cb's body reads `source`; the statement then defines CTE lk after cb (or
  # before it, with `lk_first`) and the main query joins it.
  defp query(db, source, lk_first \\ false) do
    cb = fn q ->
      Selecto.with_cte(q, "cb", body(db, source),
        columns: ["rid", "clab"],
        join: [owner_key: :id, related_key: :rid, fields: %{"clab" => %{type: :string}}]
      )
    end

    root = p(db)

    root =
      if lk_first,
        do: root |> Selecto.with_ctes([lk(db)]) |> cb.(),
        else: root |> cb.() |> Selecto.with_ctes([lk(db)])

    root
    |> Selecto.join(:lkm,
      source: "lk",
      source_kind: :cte,
      type: :left,
      owner_key: :id,
      related_key: :product_id,
      fields: @label
    )
    |> Selecto.select(["name", "cb.clab", "lkm.label"])
  end

  defp walk(query, db) do
    Selecto.with_recursive_cte(query, "walk",
      base_query: fn -> p(db) |> Selecto.select(["id"]) |> Selecto.filter({"id", 1}) end,
      recursive_query: fn _ref ->
        p(db)
        |> Selecto.join(:w,
          source: "walk",
          type: :inner,
          owner_key: :id,
          related_key: :wid,
          fields: %{"wid" => %{type: :integer}}
        )
        |> Selecto.select(["id"])
        |> Selecto.filter({"id", 999})
      end,
      columns: ["wid"],
      join: [
        owner_key: :id,
        related_key: :wid,
        type: :left,
        fields: %{"wid" => %{type: :integer}}
      ]
    )
  end

  test "a body reading a table named like a later CTE refuses, with or without RECURSIVE",
       %{db: db} do
    for q <- [query(db, "lk"), walk(query(db, "lk"), db)] do
      assert {:error,
              %Selecto.Error{
                details: %{reason: :cte_name_collision, relations: ["lk"]}
              }} = Selecto.execute(q)
    end
  end

  test "a body reading a CTE defined before it reads the CTE", %{db: db} do
    assert {:ok, {rows, _, _}} = Selecto.execute(query(db, "lk", true))
    assert Enum.sort(rows) == [["a", "a", "a"], ["b", "b", "b"]]
  end

  # Union shapes: a CTE whose body is a set operation, one whose member defines
  # its own CTE, and a top-level union member carrying a WITH.
  defp union_body(db, member_cte?) do
    fn ->
      left = p(db) |> Selecto.filter({"id", 1}) |> Selecto.select(["id", "name"])

      right =
        if member_cte? do
          own =
            Selecto.Advanced.CTE.create_cte(
              "pc",
              fn -> p(db) |> Selecto.filter({"id", 2}) |> Selecto.select(["id", "name"]) end,
              columns: ["pid", "pname"]
            )

          p(db)
          |> Selecto.with_ctes([own])
          |> Selecto.join(:pcj,
            source: "pc",
            source_kind: :cte,
            type: :inner,
            owner_key: :id,
            related_key: :pid,
            fields: %{"pname" => %{type: :string}}
          )
          |> Selecto.select(["id", "pcj.pname"])
        else
          p(db) |> Selecto.filter({"id", 2}) |> Selecto.select(["id", "name"])
        end

      Selecto.union(left, right, all: true)
    end
  end

  defp union_cte(db, member_cte?) do
    p(db)
    |> Selecto.with_cte("u", union_body(db, member_cte?),
      columns: ["uid", "uname"],
      join: [owner_key: :id, related_key: :uid, fields: %{"uname" => %{type: :string}}]
    )
    |> Selecto.select(["name", "u.uname"])
  end

  test "a CTE whose body is a union answers", %{db: db} do
    assert {:ok, {rows, _, _}} = Selecto.execute(union_cte(db, false))
    assert Enum.sort(rows) == [["a", "a"], ["b", "b"]]
  end

  test "a CTE whose union body's member defines its own CTE answers", %{db: db} do
    assert {:ok, {rows, _, _}} = Selecto.execute(union_cte(db, true))
    assert Enum.sort(rows) == [["a", "a"], ["b", "b"]]
  end

  test "a top-level union member carrying a WITH answers", %{db: db} do
    assert {:ok, {rows, _, _}} = Selecto.execute(union_body(db, true).())
    assert Enum.sort(rows) == [[1, "a"], [2, "b"]]
  end
end
