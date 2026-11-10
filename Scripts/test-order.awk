# Timing files precede the final file, which lists the current bundle paths.
# Later measurements override estimates. Ignore malformed data; never use timing
# data to decide whether a bundle runs. Unknown bundles get zero and run last.
BEGIN { FS = "\t" }
FILENAME != ARGV[ARGC - 1] {
    if ($1 ~ /^[0-9]+(\.[0-9]+)?$/ && $2 ~ /^[A-Za-z0-9_-]+$/)
        seconds[$2] = $1 + 0
    next
}
{
    name = $0
    sub(/^.*\//, "", name)
    sub(/\.xctest$/, "", name)
    printf "%.6f\t%s\n", seconds[name] + 0, $0
}
