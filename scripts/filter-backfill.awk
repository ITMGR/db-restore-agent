# Emits data-load blocks only for tables matching backfill_re.
# DDL and non-matching table data are always skipped. The target database is
# expected to already contain the schema from a previous pruned-data restore.
# Also filters out CREATE USER / GRANT / SET PASSWORD statements.

BEGIN {
  emit = 0
  current_table = ""
}

/^-- Dumping data for table `/ {
  current_table = $0
  sub(/^-- Dumping data for table `/, "", current_table)
  sub(/`.*/, "", current_table)

  if (current_table ~ backfill_re) {
    emit = 1
    print "-- crz-opt: backfilling data for table `" current_table "`" > "/dev/stderr"
    print
  } else {
    emit = 0
  }
  next
}

emit {
  print
  if ($0 ~ /^UNLOCK TABLES;/) {
    emit = 0
    current_table = ""
  }
  next
}

# Filter out privilege statements
/^(CREATE USER|GRANT|RENAME USER|SET PASSWORD|ALTER USER)/ {
  next
}