# Changelog

All notable changes to `selecto_db_sqlite` will be documented in this file.

The format is based on Keep a Changelog and this project adheres to Semantic Versioning.

## [0.1.0] - 2026-03-13

### Added
- Initial external SQLite adapter package for Selecto.
- Shared adapter contract integration via `selecto_db_adapter`.
- Core adapter callbacks: `connect/1`, `execute/4`, `placeholder/1`, `quote_identifier/1`, and `supports?/1`.
- Additional callbacks for runtime compatibility: `execute_raw/3`, `validate_connection/1`, `connection_info/1`, and `transaction/3`.
- Adapter test coverage for query execution, callback exports, validation helpers, and transaction commit/rollback behavior.
