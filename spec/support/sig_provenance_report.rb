# frozen_string_literal: true

# The markdown the two `sig/` provenance notes are made of, rendered from {SigProvenanceAuditor}'s
# rows. Presentation only — it decides nothing, so a table that reads oddly is a rendering bug and
# never a classification one.
#
# Separate from the auditor because the notes cite the report VERBATIM
# (`docs/notes/20260908-sig-provenance-audit.md`, `docs/notes/20260909-sig-no-source-audit.md`): the
# tables and the gate must come from one pass or they drift, and keeping the rendering out of the
# classifier is what stops "make the table nicer" from touching the classification.
#
# Deliberately no `require` of the auditor: it is the caller, it hands over the rows, and every
# constant read below resolves at call time.
class SigProvenanceReport
  class << self
    def render(rows, out: $stdout)
      out.puts("| classification | n |\n| --- | --- |")
      rows.group_by(&:classification).sort_by { |_, group| -group.size }
          .each { |state, group| out.puts("| `#{state}` | #{group.size} |") }
      per_file(rows, out)
      out.puts("\n### tighter-return (a marker is required on every one)\n")
      rows.select { |row| row.classification == SigProvenanceAuditor::TIGHTER_RETURN }
          .each { |row| out.puts("- #{row}") }
      unattributed(rows, out)
    end

    private

    def columns = [SigProvenanceAuditor::TIGHTER_RETURN] + SigProvenanceAuditor::RESIDUE

    # Issue #839's own table: for every declaration `sig-gen` could attribute no `def` to, WHY the
    # static scan found none. A `no_source` row here is a stale declaration, and is listed in full
    # because the gate fails on it.
    def unattributed(rows, out)
      states = [SigProvenanceAuditor::SYNTHETIC, SigProvenanceAuditor::INHERITED,
                SigProvenanceAuditor::RUNTIME_DEFINED, SigProvenanceAuditor::NO_SOURCE]
      found = rows.select { |row| states.include?(row.classification) }
      out.puts("\n### where a declaration with no attributed `def` comes from (#{found.size})\n")
      out.puts("| classification | shape | n |\n| --- | --- | --- |")
      found.group_by { |row| [row.classification, row.detail] }.sort_by { |_, group| -group.size }
           .each { |(state, shape), group| out.puts("| `#{state}` | #{shape || '—'} | #{group.size} |") }
      stale = found.select { |row| row.classification == SigProvenanceAuditor::NO_SOURCE }
      out.puts("\n### stale declarations (#{stale.size})\n")
      stale.each { |row| out.puts("- #{row.declaration} — no source") }
    end

    def per_file(rows, out)
      out.puts("\n| file | #{columns.map { |state| "`#{state}`" }.join(' | ')} | earned | residue |")
      out.puts("| --- |#{' --- |' * (columns.size + 2)}")
      rows.reject { |row| row.classification == SigProvenanceAuditor::NON_METHOD }
          .group_by { |row| row.declaration.path }.sort
          .each { |path, file_rows| out.puts(file_row(path, file_rows)) }
    end

    def file_row(path, rows)
      by = rows.group_by(&:classification)
      cells = columns.map { |state| by.fetch(state, []).size }
      earned = SigProvenanceAuditor::EARNED.sum { |state| by.fetch(state, []).size }
      "| `#{path}` | #{cells.join(' | ')} | #{earned} | #{rows.count(&:residue?)} |"
    end
  end
end
