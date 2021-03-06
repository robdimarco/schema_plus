module SchemaPlus
  module ActiveRecord
    module ConnectionAdapters
      # SchemaPlus includes a MySQL implementation of the AbstractAdapter
      # extensions.  (This works with both the <tt>mysql</t> and
      # <tt>mysql2</tt> gems.)
      module MysqlAdapter

        #:enddoc:
        
        def self.included(base)
          base.class_eval do
            alias_method_chain :tables, :schema_plus
            alias_method_chain :remove_column, :schema_plus
            alias_method_chain :rename_table, :schema_plus
            alias_method_chain :exec_stmt, :schema_plus rescue nil # only defined for mysql not mysql2
          end
        end

        def tables_with_schema_plus(name=nil, *args)
          tables_without_schema_plus(name, *args) - views(name)
        end

        def remove_column_with_schema_plus(table_name, column_name)
          foreign_keys(table_name).select { |foreign_key| foreign_key.column_names.include?(column_name.to_s) }.each do |foreign_key|
            remove_foreign_key(table_name, foreign_key.name)
          end
          remove_column_without_schema_plus(table_name, column_name)
        end

        def rename_table_with_schema_plus(oldname, newname)
          rename_table_without_schema_plus(oldname, newname)
          rename_indexes_and_foreign_keys(oldname, newname)
        end

        # used only for mysql not mysql2.  the quoting methods on ActiveRecord::DB_DEFAULT are
        # sufficient for mysql2
        def exec_stmt_with_schema_plus(sql, name, binds, &block)
          if binds.any?{ |col, val| val.equal? ::ActiveRecord::DB_DEFAULT}
            binds.each_with_index do |(col, val), i|
              if val.equal? ::ActiveRecord::DB_DEFAULT
                sql = sql.sub(/(([^?]*?){#{i}}[^?]*)\?/, "\\1DEFAULT")
              end
            end
            binds = binds.reject{|col, val| val.equal? ::ActiveRecord::DB_DEFAULT}
          end
          exec_stmt_without_schema_plus(sql, name, binds, &block)
        end

        def remove_foreign_key(table_name, foreign_key_name, options = {})
          execute "ALTER TABLE #{quote_table_name(table_name)} DROP FOREIGN KEY #{foreign_key_name}"
        end

        def foreign_keys(table_name, name = nil)
          results = execute("SHOW CREATE TABLE #{quote_table_name(table_name)}", name)

          table_name = table_name.to_s
          namespace_prefix = table_namespace_prefix(table_name)

          foreign_keys = []

          results.each do |row|
            row[1].lines.each do |line|
              if line =~ /^  CONSTRAINT [`"](.+?)[`"] FOREIGN KEY \([`"](.+?)[`"]\) REFERENCES [`"](.+?)[`"] \((.+?)\)( ON DELETE (.+?))?( ON UPDATE (.+?))?,?$/
                name = $1
                column_names = $2
                references_table_name = $3
                references_table_name = namespace_prefix + references_table_name if table_namespace_prefix(references_table_name).blank?
                references_column_names = $4
                on_update = $8
                on_delete = $6
                on_update = on_update ? on_update.downcase.gsub(' ', '_').to_sym : :restrict
                on_delete = on_delete ? on_delete.downcase.gsub(' ', '_').to_sym : :restrict

                foreign_keys << ForeignKeyDefinition.new(name,
                                                         namespace_prefix + table_name, column_names.gsub('`', '').split(', '),
                                                         references_table_name, references_column_names.gsub('`', '').split(', '),
                                                         on_update, on_delete)
              end
            end
          end

          foreign_keys
        end

        def reverse_foreign_keys(table_name, name = nil)
          results = execute(<<-SQL, name)
        SELECT constraint_name, table_name, column_name, referenced_table_name, referenced_column_name
          FROM information_schema.key_column_usage
         WHERE table_schema = #{table_schema_sql(table_name)}
           AND referenced_table_schema = table_schema
         ORDER BY constraint_name, ordinal_position;
          SQL
          current_foreign_key = nil
          foreign_keys = []

          namespace_prefix = table_namespace_prefix(table_name)

          results.each do |row|
            next unless table_name_without_namespace(table_name).casecmp(row[3]) == 0
            if current_foreign_key != row[0]
                referenced_table_name = row[1]
                referenced_table_name = namespace_prefix + referenced_table_name if table_namespace_prefix(referenced_table_name).blank?
                references_table_name = row[3]
                references_table_name = namespace_prefix + references_table_name if table_namespace_prefix(references_table_name).blank?
              foreign_keys << ForeignKeyDefinition.new(row[0], referenced_table_name, [], references_table_name, [])
              current_foreign_key = row[0]
            end

            foreign_keys.last.column_names << row[2]
            foreign_keys.last.references_column_names << row[4]
          end

          foreign_keys
        end

        def views(name = nil)
          views = []
          execute("SELECT table_name FROM information_schema.views WHERE table_schema = SCHEMA()", name).each do |row|
            views << row[0]
          end
          views
        end

        def view_definition(view_name, name = nil)
          result = execute("SELECT view_definition, check_option FROM information_schema.views WHERE table_schema = SCHEMA() AND table_name = #{quote(view_name)}", name)
          return nil unless (result.respond_to?(:num_rows) ? result.num_rows : result.to_a.size) > 0 # mysql vs mysql2
          row = result.respond_to?(:fetch_row) ? result.fetch_row : result.first
          sql = row[0]
          sql.gsub!(%r{#{quote_table_name(current_database)}[.]}, '')
          case row[1]
          when "CASCADED" then sql += " WITH CASCADED CHECK OPTION"
          when "LOCAL" then sql += " WITH LOCAL CHECK OPTION"
          end
          sql
        end

        def default_expr_valid?(expr)
          false # only the TIMESTAMP column accepts SQL column defaults and rails uses DATETIME
        end

        def sql_for_function(function)
          case function
          when :now then 'CURRENT_TIMESTAMP'
          end
        end

        private

        def table_namespace_prefix(table_name)
          table_name.to_s =~ /(.*[.])/ ? $1 : ""
        end

        def table_schema_sql(table_name)
          table_name.to_s =~ /(.*)[.]/ ? "'#{$1}'" : "SCHEMA()"
        end

        def table_name_without_namespace(table_name)
          table_name.to_s.sub /.*[.]/, ''
        end

      end
    end
  end
end
