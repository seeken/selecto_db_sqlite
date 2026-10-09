defmodule SelectoDBSQLite.CoDomainFtsLookupTest do
  use ExUnit.Case, async: false
  alias SelectoDBSQLite.Adapter

  def domain do
    %{
      schema_version: 1,
      name: "CertificationPeopleLookup",
      source: %{
        source_table: "selecto_cert_people",
        primary_key: :id,
        fields: [:id, :name, :nickname, :active, :score, :joined_on, :created_at, :eligible],
        columns: %{
          id: %{type: :integer},
          name: %{type: :string},
          nickname: %{type: :string, label: "Nickname"},
          active: %{type: :boolean},
          score: %{type: :decimal},
          joined_on: %{type: :date},
          created_at: %{type: :naive_datetime},
          eligible: %{
            type: :boolean,
            internal: true,
            computed: %{kind: :predicate, expression: ["eq", "nickname", "ada"]}
          }
        },
        associations: %{},
        fts5_index: %{table: "selecto_cert_people_fts", key: :id}
      },
      schemas: %{},
      joins: %{},
      query_library: %{
        segments: %{active: %{filters: [{:nickname, "ada"}]}},
        projections: %{identity: %{fields: [:id, :name, :nickname]}},
        views: %{lookup: %{segments: [:active], projection: :identity}}
      },
      co_domains: %{
        people: %{
          domain: :people,
          view: :lookup,
          search: %{fields: [:name], configuration: "simple", mode: :prefix, rank: true},
          result: %{value_field: :id, label_field: :name, description_fields: [:nickname]}
        }
      },
      actions: %{dispatch: %{type: :update, selection: %{eligibility_field: :eligible}}}
    }
  end

  def sql(db, statement) do
    assert {:ok, %{rows: rows}} = Adapter.execute(db, statement, [], [])
    rows
  end

  setup do
    {:ok, db} = Adapter.connect(database: ":memory:", temp_store: :memory)

    sql(
      db,
      "CREATE TABLE selecto_cert_people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, nickname TEXT, active BOOLEAN, score DECIMAL(12,2), joined_on DATE, created_at DATETIME)"
    )

    sql(
      db,
      "INSERT INTO selecto_cert_people VALUES (1,'Ada Lovelace','ada',1,10.50,'2024-01-01','2024-01-01 10:00:00'),(2,'Grace Hopper',NULL,1,20,'2024-01-02','2024-01-02 11:30:00'),(3,'Renée 東京','O''Brien',0,20.25,'2024-02-01','2024-02-01 09:15:00'),(4,'Linus Torvalds',NULL,1,NULL,'2024-03-01','2024-03-01 08:00:00')"
    )

    index(db)
    on_exit(fn -> Adapter.disconnect(db) end)
    assert Enum.all?(sql(db, "PRAGMA database_list"), fn [_, _, file] -> file == "" end)
    assert sql(db, "PRAGMA temp_store") == [[2]]
    %{db: db}
  end

  def index(db, arguments \\ "name, content='selecto_cert_people', content_rowid='id'") do
    sql(db, "CREATE VIRTUAL TABLE selecto_cert_people_fts USING fts5(" <> arguments <> ")")
    sql(db, "INSERT INTO selecto_cert_people_fts(selecto_cert_people_fts) VALUES('rebuild')")
  end

  def target(db, authored \\ domain()),
    do: Selecto.configure(authored, Selecto.Runtime.Context.new(Adapter, db), adapter: Adapter)

  test "D080 mapping, named and request scopes, tokenless result and bound rank", %{db: db} do
    authored = domain()
    query = target(db)

    assert {:ok, %{results: [%{value: "1", label: "Ada Lovelace", description: "Nickname ada"}]}} =
             Selecto.CoDomain.lookup(authored, query, "people", "Ada'); --",
               scope: {"id", {:<=, 1}},
               limit: 1
             )

    for {text, opts} <- [{"Ada", [scope: {"id", {:<, 1}}]}, {"Ren", []}, {"---", []}] do
      assert {:ok, %{results: []}} =
               Selecto.CoDomain.lookup(authored, query, "people", text, opts)
    end

    plan =
      Selecto.CoDomain.plan(authored, query, "people", "Ada'); --",
        scope: {"id", {:<=, 1}},
        limit: 1
      )

    {text, params} = Selecto.to_sql(plan.query)
    refute text =~ "Ada'); --"
    assert "ada:*" in List.flatten(params)
    assert text =~ "-bm25"
    assert text =~ "main."
    assert plan.query.set.limit == 1
    assert query.domain == authored
    assert sql(db, "PRAGMA query_only") == [[0]]
  end

  test "plain and phrase modes bind text while requested fields constrain MATCH", %{db: db} do
    for {mode, text, count} <- [
          {:plain, "Ada Lovelace", 1},
          {:phrase, "Ada Lovelace", 1},
          {:plain, "Nickname", 0}
        ] do
      authored = put_in(domain(), [:co_domains, :people, :search, :mode], mode)

      assert {:ok, %{results: results}} =
               Selecto.CoDomain.lookup(authored, target(db, authored), :people, text)

      assert length(results) == count
    end
  end

  test "descending relevance ranks two extra matches ahead of declared order", %{db: db} do
    sql(
      db,
      "INSERT INTO selecto_cert_people(id,name,nickname) VALUES(5,'Ada Ada Ada Ada Ada','ada'),(6,'Ada " <>
        String.duplicate("word ", 30) <> "','ada')"
    )

    sql(db, "INSERT INTO selecto_cert_people_fts(selecto_cert_people_fts) VALUES('rebuild')")

    authored =
      domain()
      |> put_in([:query_library, :orderings], %{identity: %{order_by: [{:asc, :id}]}})
      |> put_in([:query_library, :views, :lookup, :ordering], :identity)

    native =
      sql(
        db,
        "SELECT rowid FROM main.selecto_cert_people_fts WHERE selecto_cert_people_fts MATCH '{name}:(ada*)' ORDER BY bm25(selecto_cert_people_fts),rowid"
      )

    assert native == [[5], [1], [6]]

    assert {:ok, %{results: results}} =
             Selecto.CoDomain.lookup(authored, target(db, authored), :people, "Ada'); --",
               scope: {"id", {:<=, 5}},
               limit: 2
             )

    assert Enum.map(results, & &1.value) == ["5", "1"]

    assert {:ok, %{results: results}} =
             Selecto.CoDomain.lookup(authored, target(db, authored), :people, "Ada", limit: 3)

    assert Enum.map(results, & &1.value) == ["5", "1", "6"]
  end

  test "required and trusted tenant scopes intersect named and request scopes", %{db: db} do
    sql(db, "ALTER TABLE selecto_cert_people ADD COLUMN tenant_id INTEGER")
    sql(db, "UPDATE selecto_cert_people SET tenant_id=7")

    authored =
      domain()
      |> put_in([:source, :tenant_field], :tenant_id)
      |> update_in([:source, :fields], &(&1 ++ [:tenant_id]))
      |> put_in([:source, :columns, :tenant_id], %{type: :integer})

    query = target(db, authored)

    assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
             Selecto.CoDomain.lookup(authored, query, :people, "Ada", scope: {"id", 1})

    assert {:error, %Selecto.Error{details: %{code: :missing_tenant_scope}}} =
             Selecto.CoDomain.lookup(authored, query, :people, "---")

    for {tenant, count} <- [{7, 1}, {8, 0}] do
      assert {:ok, %{results: results}} =
               Selecto.CoDomain.lookup(
                 authored,
                 Selecto.with_tenant(query, %{tenant_id: tenant, tenant_field: "tenant_id"}),
                 :people,
                 "Ada",
                 scope: {"id", 1}
               )

      assert length(results) == count
    end

    required = Map.put(authored, :required_filters, [{"id", {:<, 1}}])

    assert {:ok, %{results: []}} =
             Selecto.CoDomain.lookup(
               required,
               Selecto.with_tenant(target(db, required), %{
                 tenant_id: 7,
                 tenant_field: "tenant_id"
               }),
               :people,
               "Ada"
             )
  end

  test "missing index, root/key mismatch, tokenizer, detail and unindexed columns refuse", %{
    db: db
  } do
    for arguments <- [
          "name,content='selecto_cert_people',content_rowid='id',tokenize='porter'",
          "name,content='selecto_cert_people',content_rowid='id',detail='column'",
          "name UNINDEXED,content='selecto_cert_people',content_rowid='id'",
          "nickname,content='selecto_cert_people',content_rowid='id'",
          "name,content='selecto_cert_people',content_rowid='score'"
        ] do
      sql(db, "DROP TABLE selecto_cert_people_fts")
      index(db, arguments)

      assert_raise ArgumentError, fn ->
        Selecto.CoDomain.plan(domain(), target(db), :people, "Ada")
      end

      assert sql(db, "PRAGMA query_only") == [[0]]
    end

    sql(db, "DROP TABLE selecto_cert_people_fts")

    assert_raise ArgumentError, fn ->
      Selecto.CoDomain.plan(domain(), target(db), :people, "Ada")
    end
  end

  test "TEMP shadows refuse and metadata tables cannot spoof native catalog authority", %{db: db} do
    for name <- ["selecto_cert_people", "selecto_cert_people_fts"] do
      sql(db, "CREATE TEMP TABLE " <> name <> "(id INTEGER PRIMARY KEY,name TEXT)")

      assert_raise ArgumentError, fn ->
        Selecto.CoDomain.plan(domain(), target(db), :people, "Ada")
      end

      sql(db, "DROP TABLE temp." <> name)
    end

    for schema <- ["main", "temp"] do
      sql(
        db,
        "CREATE TABLE " <>
          schema <> ".pragma_table_list(schema TEXT,name TEXT,type TEXT,wr INTEGER)"
      )

      sql(
        db,
        "CREATE TABLE " <>
          schema <> ".pragma_table_xinfo(name TEXT,type TEXT,pk INTEGER,hidden INTEGER)"
      )
    end

    assert {:ok, %{results: [_]}} = Selecto.CoDomain.lookup(domain(), target(db), :people, "Ada")
    sql(db, "DROP TABLE selecto_cert_people_fts")
    sql(db, "CREATE TABLE selecto_cert_people_fts(name TEXT)")

    assert_raise ArgumentError, fn ->
      Selecto.CoDomain.plan(domain(), target(db), :people, "Ada")
    end
  end

  test "native ordinary root, one INTEGER rowid key and visible text are required", %{db: db} do
    for ddl <- [
          "CREATE TABLE selecto_cert_people(id INT PRIMARY KEY,name TEXT)",
          "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY DESC,name TEXT)",
          "CREATE TABLE selecto_cert_people(id INTEGER,name TEXT,PRIMARY KEY(id,name))",
          "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name TEXT) WITHOUT ROWID",
          "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name TEXT GENERATED ALWAYS AS ('Ada') STORED)",
          "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name INTEGER)",
          "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name CHARINT)",
          "CREATE VIEW selecto_cert_people AS SELECT 1 AS id,'Ada' AS name"
        ] do
      sql(db, "DROP TABLE selecto_cert_people_fts")
      sql(db, "DROP TABLE selecto_cert_people")
      sql(db, ddl)
      index(db)

      assert_raise ArgumentError, fn ->
        Selecto.CoDomain.plan(domain(), target(db), :people, "Ada")
      end

      assert sql(db, "PRAGMA query_only") == [[0]]

      if String.starts_with?(ddl, "CREATE VIEW") do
        sql(db, "DROP TABLE selecto_cert_people_fts")
        sql(db, "DROP VIEW selecto_cert_people")
        sql(db, "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name TEXT)")
        index(db)
      end
    end
  end

  test "rowid alias proof rejects nullable column DESC and accepts table-level DESC", %{db: db} do
    sql(db, "DROP TABLE selecto_cert_people_fts")
    sql(db, "DROP TABLE selecto_cert_people")

    sql(
      db,
      "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY DESC,name TEXT,nickname TEXT)"
    )

    sql(db, "INSERT INTO selecto_cert_people VALUES(NULL,'Ada one','ada'),(NULL,'Ada two','ada')")

    assert sql(db, "SELECT rowid,id FROM selecto_cert_people ORDER BY rowid") == [
             [1, nil],
             [2, nil]
           ]

    assert Enum.any?(sql(db, "PRAGMA main.index_list('selecto_cert_people')"), fn [
                                                                                    _,
                                                                                    _,
                                                                                    _,
                                                                                    origin,
                                                                                    _
                                                                                  ] ->
             origin == "pk"
           end)

    index(db)

    assert_raise ArgumentError, fn ->
      Selecto.CoDomain.plan(domain(), target(db), :people, "Ada")
    end

    assert sql(db, "PRAGMA query_only") == [[0]]
    sql(db, "DROP TABLE selecto_cert_people_fts")
    sql(db, "DROP TABLE selecto_cert_people")

    sql(
      db,
      "CREATE TABLE selecto_cert_people(id INTEGER,name TEXT,nickname TEXT,PRIMARY KEY(id DESC))"
    )

    sql(db, "INSERT INTO selecto_cert_people VALUES(NULL,'Ada alias','ada')")
    assert sql(db, "SELECT rowid,id FROM selecto_cert_people") == [[1, 1]]
    assert sql(db, "PRAGMA main.index_list('selecto_cert_people')") == []
    index(db)

    assert {:ok, %{results: [%{value: "1", label: "Ada alias"}]}} =
             Selecto.CoDomain.lookup(domain(), target(db), :people, "Ada")
  end

  test "native TEXT affinity accepts VARCHAR and decorated TEXT without INTEGER precedence", %{
    db: db
  } do
    for type <- ["VARCHAR(100)", "CLOB", "TEXT(100)"] do
      sql(db, "DROP TABLE selecto_cert_people_fts")
      sql(db, "DROP TABLE selecto_cert_people")

      sql(
        db,
        "CREATE TABLE selecto_cert_people(id INTEGER PRIMARY KEY,name " <>
          type <> ",nickname TEXT)"
      )

      sql(db, "INSERT INTO selecto_cert_people VALUES(1,'Ada text','ada')")
      index(db)

      assert {:ok, %{results: [%{value: "1", label: "Ada text"}]}} =
               Selecto.CoDomain.lookup(domain(), target(db), :people, "Ada")
    end
  end

  test "public stored root fields, simple configuration and bounded input are required", %{db: db} do
    for authored <- [
          put_in(domain(), [:source, :columns, :name, :internal], true),
          put_in(domain(), [:source, :columns, :name, :computed], %{
            kind: :value,
            expression: ["literal", "Ada"]
          }),
          put_in(domain(), [:co_domains, :people, :search, :configuration], "english")
        ] do
      assert_raise ArgumentError, fn ->
        Selecto.CoDomain.plan(authored, target(db, authored), :people, "Ada")
      end
    end

    for {text, opts} <- [
          {"Ada", [limit: 101]},
          {"Ada", [limit: 0]},
          {"Ada\0", []},
          {String.duplicate("a", 201), []}
        ] do
      assert_raise ArgumentError, fn ->
        Selecto.CoDomain.plan(domain(), target(db), :people, text, opts)
      end
    end

    assert_raise ArgumentError, fn ->
      Selecto.CoDomain.plan(domain(), target(:compile_only), :people, "Ada")
    end

    sql(db, "PRAGMA query_only=ON")
    assert {:ok, %{results: [_]}} = Selecto.CoDomain.lookup(domain(), target(db), :people, "Ada")
    assert sql(db, "PRAGMA query_only") == [[1]]
  end

  test "joined fields and undeclared indexes cannot turn into lookup grants", %{db: db} do
    authored =
      domain()
      |> put_in([:source, :associations, :other], %{
        queryable: :other,
        owner_key: :id,
        related_key: :id
      })
      |> put_in([:schemas, :other], %{
        source_table: "other",
        redact_fields: [],
        primary_key: :id,
        fields: [:id, :name],
        columns: %{id: %{type: :integer}, name: %{type: :string}},
        associations: %{}
      })
      |> put_in([:joins, :other], %{type: :left, name: "Other"})
      |> put_in([:co_domains, :people, :search, :fields], ["other.name"])

    assert_raise ArgumentError, fn ->
      Selecto.CoDomain.plan(authored, target(db, authored), :people, "Ada")
    end

    undeclared = update_in(domain(), [:source], &Map.delete(&1, :fts5_index))

    assert_raise ArgumentError, fn ->
      Selecto.CoDomain.plan(undeclared, target(db, undeclared), :people, "Ada")
    end

    refute Map.has_key?(target(db, undeclared).domain.source, :fts5_index)

    assert sql(db, "SELECT id,name FROM selecto_cert_people ORDER BY id") ==
             [[1, "Ada Lovelace"], [2, "Grace Hopper"], [3, "Renée 東京"], [4, "Linus Torvalds"]]
  end
end
