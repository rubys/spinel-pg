# ErrorResponse diagnostics and the pg-gem exception names needed by shared
# SQLSTATE mapping. Flat typed arrays keep this usable under Spinel too.
require "pg/wire"

module PG
  PG_DIAG_SEVERITY = 83
  PG_DIAG_SEVERITY_NONLOCALIZED = 86
  PG_DIAG_SQLSTATE = 67
  PG_DIAG_MESSAGE_PRIMARY = 77
  PG_DIAG_MESSAGE_DETAIL = 68
  PG_DIAG_MESSAGE_HINT = 72
  PG_DIAG_STATEMENT_POSITION = 80
  PG_DIAG_INTERNAL_POSITION = 112
  PG_DIAG_INTERNAL_QUERY = 113
  PG_DIAG_CONTEXT = 87
  PG_DIAG_SCHEMA_NAME = 115
  PG_DIAG_TABLE_NAME = 116
  PG_DIAG_COLUMN_NAME = 99
  PG_DIAG_DATATYPE_NAME = 100
  PG_DIAG_CONSTRAINT_NAME = 110
  PG_DIAG_SOURCE_FILE = 70
  PG_DIAG_SOURCE_LINE = 76
  PG_DIAG_SOURCE_FUNCTION = 82

  # Match pg: Rails leaves RuntimeError unchanged in its generic translation,
  # but wraps otherwise unmapped server errors in StatementInvalid.
  class Error < StandardError
    def initialize(message, result)
      super(message)
      @result = result
    end

    def result
      @result
    end

    def error
      self.message
    end
  end

  class ServerError < Error; end
  class FeatureNotSupported < ServerError; end
  class ConnectionException < ServerError; end
  class DataException < ServerError; end
  class StringDataRightTruncation < DataException; end
  class NumericValueOutOfRange < DataException; end
  class DivisionByZero < DataException; end
  class InvalidTextRepresentation < DataException; end
  class IntegrityConstraintViolation < ServerError; end
  class NotNullViolation < IntegrityConstraintViolation; end
  class ForeignKeyViolation < IntegrityConstraintViolation; end
  class UniqueViolation < IntegrityConstraintViolation; end
  class CheckViolation < IntegrityConstraintViolation; end
  class ExclusionViolation < IntegrityConstraintViolation; end
  class InvalidTransactionState < ServerError; end
  class InFailedSqlTransaction < InvalidTransactionState; end
  class InvalidSqlStatementName < ServerError; end
  class InvalidAuthorizationSpecification < ServerError; end
  class InvalidPassword < InvalidAuthorizationSpecification; end
  class InvalidCatalogName < ServerError; end
  class TransactionRollback < ServerError; end
  class TRSerializationFailure < TransactionRollback; end
  class TRDeadlockDetected < TransactionRollback; end
  class SyntaxErrorOrAccessRuleViolation < ServerError; end
  class SyntaxError < SyntaxErrorOrAccessRuleViolation; end
  class UndefinedColumn < SyntaxErrorOrAccessRuleViolation; end
  class UndefinedTable < SyntaxErrorOrAccessRuleViolation; end
  class DuplicateDatabase < SyntaxErrorOrAccessRuleViolation; end
  class InsufficientResources < ServerError; end
  class ObjectNotInPrerequisiteState < ServerError; end
  class LockNotAvailable < ObjectNotInPrerequisiteState; end
  class OperatorIntervention < ServerError; end
  class QueryCanceled < OperatorIntervention; end
  class AdminShutdown < OperatorIntervention; end
  class InternalError < ServerError; end

  # Static construction avoids a heterogeneous class hash / dynamic new at
  # Spinel call sites. Unlisted codes fall back to their included code class.
  def self.raise_server_error(body)
    result = PgErrorResult.new(body)
    message = "pg: " + result.error_field(PG_DIAG_SEVERITY).to_s + ": " +
              result.error_field(PG_DIAG_MESSAGE_PRIMARY).to_s
    code = result.error_field(PG_DIAG_SQLSTATE).to_s
    case code
    when "22001"
      raise StringDataRightTruncation.new(message, result)
    when "22003"
      raise NumericValueOutOfRange.new(message, result)
    when "22012"
      raise DivisionByZero.new(message, result)
    when "22P02"
      raise InvalidTextRepresentation.new(message, result)
    when "23502"
      raise NotNullViolation.new(message, result)
    when "23503"
      raise ForeignKeyViolation.new(message, result)
    when "23505"
      raise UniqueViolation.new(message, result)
    when "23514"
      raise CheckViolation.new(message, result)
    when "23P01"
      raise ExclusionViolation.new(message, result)
    when "25P02"
      raise InFailedSqlTransaction.new(message, result)
    when "28P01"
      raise InvalidPassword.new(message, result)
    when "40001"
      raise TRSerializationFailure.new(message, result)
    when "40P01"
      raise TRDeadlockDetected.new(message, result)
    when "42601"
      raise SyntaxError.new(message, result)
    when "42703"
      raise UndefinedColumn.new(message, result)
    when "42P01"
      raise UndefinedTable.new(message, result)
    when "42P04"
      raise DuplicateDatabase.new(message, result)
    when "55P03"
      raise LockNotAvailable.new(message, result)
    when "57014"
      raise QueryCanceled.new(message, result)
    when "57P01"
      raise AdminShutdown.new(message, result)
    end
    case code.byteslice(0, 2)
    when "0A"
      raise FeatureNotSupported.new(message, result)
    when "08"
      raise ConnectionException.new(message, result)
    when "22"
      raise DataException.new(message, result)
    when "23"
      raise IntegrityConstraintViolation.new(message, result)
    when "25"
      raise InvalidTransactionState.new(message, result)
    when "26"
      raise InvalidSqlStatementName.new(message, result)
    when "28"
      raise InvalidAuthorizationSpecification.new(message, result)
    when "3D"
      raise InvalidCatalogName.new(message, result)
    when "40"
      raise TransactionRollback.new(message, result)
    when "42"
      raise SyntaxErrorOrAccessRuleViolation.new(message, result)
    when "53"
      raise InsufficientResources.new(message, result)
    when "55"
      raise ObjectNotInPrerequisiteState.new(message, result)
    when "57"
      raise OperatorIntervention.new(message, result)
    when "XX"
      raise InternalError.new(message, result)
    end
    raise ServerError.new(message, result)
  end
end

# The diagnostic result attached to a server exception. Parse every token,
# including future ones, once; missing fields are nil, present empty fields
# are "". Field identifiers are the same integer byte values libpq uses.
class PgErrorResult
  def initialize(body)
    @codes = [0]
    @codes.delete_at(0)
    @values = [""]
    @values.delete_at(0)
    i = 0
    while i < body.bytesize
      code = body.getbyte(i)
      if code == 0
        break
      end
      start = i + 1
      i = start
      while i < body.bytesize && body.getbyte(i) != 0
        i = i + 1
      end
      @codes.push(code)
      @values.push(body.byteslice(start, i - start).force_encoding("UTF-8"))
      i = i + 1
    end
  end

  def error_field(code)
    i = 0
    while i < @codes.length
      if @codes[i] == code
        return @values[i]
      end
      i = i + 1
    end
    nil
  end

  # The pg gem exposes both spellings.
  def result_error_field(code)
    error_field(code)
  end
end
