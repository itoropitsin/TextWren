function valid_version(value) {
  return value ~ /^[0-9]+(\.[0-9]+)*$/
}

BEGIN {
  if (!valid_version(candidate_version) || !valid_version(installed_version) ||
      candidate_build !~ /^[0-9]+$/ || installed_build !~ /^[0-9]+$/) {
    exit 2
  }

  candidate_count = split(candidate_version, candidate_parts, "[.]")
  installed_count = split(installed_version, installed_parts, "[.]")
  count = candidate_count > installed_count ? candidate_count : installed_count
  for (i = 1; i <= count; i++) {
    candidate_part = (i <= candidate_count ? candidate_parts[i] + 0 : 0)
    installed_part = (i <= installed_count ? installed_parts[i] + 0 : 0)
    if (candidate_part < installed_part) { print -1; exit }
    if (candidate_part > installed_part) { print 1; exit }
  }

  candidate_build_number = candidate_build + 0
  installed_build_number = installed_build + 0
  if (candidate_build_number < installed_build_number) { print -1; exit }
  if (candidate_build_number > installed_build_number) { print 1; exit }
  print 0
}
