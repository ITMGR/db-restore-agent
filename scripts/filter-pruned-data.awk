# Keeps DDL for every table, but removes data-load blocks for tables matching
# prune_re. Also filters out CREATE USER / GRANT / SET PASSWORD statements that
# require privileges the crz user doesn't have.
# The input is expected to be a plain mysqldump/MariaDB dump.

function emit_pruned_table(table) {
  if (!(table in pruned)) {
    pruned[table] = 1
    print "-- crz-opt: pruned data for table `" table "`" > "/dev/stderr"
  }
}

BEGIN {
  skip_data = 0
  current_table = ""
  table_count = 0
}

/^-- Dumping data for table `/ {
  # Commit previous table's data before starting next
  if (table_count > 0) {
    print "COMMIT;"
    print "SET SESSION autocommit=0;"
  }
  table_count++
  current_table = $0
  sub(/^-- Dumping data for table `/, "", current_table)
  sub(/`.*/, "", current_table)
  if (current_table ~ prune_re) {
    skip_data = 1
    emit_pruned_table(current_table)
    next
  }
}

skip_data {
  if ($0 ~ /^UNLOCK TABLES;/) {
    skip_data = 0
    current_table = ""
  }
  next
}

# Filter out privilege statements that require CREATE USER / GRANT privilege
/^(CREATE USER|GRANT|RENAME USER|SET PASSWORD|ALTER USER)/ {
  next
}

{
  print
}