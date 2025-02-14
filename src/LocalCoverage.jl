module LocalCoverage

using CoverageTools
using DocStringExtensions
using Printf
using PrettyTables
using DefaultApplication
using LibGit2
import Pkg

export generate_coverage, clean_coverage, report_coverage, html_coverage, generate_xml

"Directory for coverage results."
const COVDIR = "coverage"

"Coverage tracefile."
const LCOVINFO = "lcov.info"

"""
Summarized coverage data about a single file. Evaluated for all files of a package
to compose a `PackageCoverage`.

$(FIELDS)
"""
Base.@kwdef struct FileCoverageSummary
    "File path relative to the directory of the project"
    filename::String
    "Number of lines covered by tests"
    lines_hit::Int
    "Number of lines with content to be tested"
    lines_tracked::Int
    "Percentage of lines covered"
    coverage::Float64
    "List of all line ranges without coverage"
    coverage_gaps::Vector{UnitRange{Int}}
end

"""
Summarized coverage data about a specific package. Contains a list of
`FileCoverageSummary` relative to the package files as well as global metrics
about the package coverage.

See [`report_coverage`](@ref).

$(FIELDS)
"""
Base.@kwdef struct PackageCoverage
    "Absolute path of the package"
    package_dir::String
    "List of files coverage summaries tracked"
    files::Vector{FileCoverageSummary}
    "Total number of lines covered by tests in the package"
    lines_hit::Int
    "Total number of lines with content to be tested in the package"
    lines_tracked::Int
    "Percentage of package lines covered"
    coverage::Float64
end

"""
$(SIGNATURES)

Get the root directory of a package. For `nothing`, fall back to the active project.
"""
pkgdir(pkgstr::AbstractString) = abspath(joinpath(dirname(Base.find_package(pkgstr)), ".."))

pkgdir(::Nothing) = dirname(Base.active_project())

"""
$(SIGNATURES)

Evaluate the ranges of lines without coverage.

`coverage` is the vector of coverage counts for each line.
"""
function find_gaps(coverage)
    i, last_line = firstindex(coverage), lastindex(coverage)
    gaps = UnitRange{Int}[]
    while i < last_line
        gap_start = i = findnext(x -> !isnothing(x) && iszero(x), coverage, i)
        isnothing(gap_start) && break
        gap_end =
            i = something(
                findnext(x -> isnothing(x) || !iszero(x), coverage, i),
                last_line + 1,
            )
        push!(gaps, gap_start:(gap_end-1))
    end
    gaps
end


"""
$(SIGNATURES)

Evaluate the coverage metrics for the given pkg.
"""
function eval_coverage_metrics(coverage, package_dir)
    coverage_list = map(coverage) do file
        tracked = count(!isnothing, file.coverage)
        gaps = find_gaps(file.coverage)
        hit = tracked - sum(length.(gaps))

        FileCoverageSummary(file.filename, hit, tracked, 100 * hit / tracked, gaps)
    end

    total_hit = sum(getfield.(coverage_list, :lines_hit))
    total_tracked = sum(getfield.(coverage_list, :lines_tracked))

    PackageCoverage(
        package_dir,
        coverage_list,
        total_hit,
        total_tracked,
        100 * total_hit / total_tracked,
    )
end

"""
$(SIGNATURES)

Generate a PackageCoverage that summarizes coverage results for package `pkg`.

If no pkg is supplied, the method operates in the currently active pkg.

A percentage target_coverage may be specified to control the color coding of the
pretty printed results.

The test execution step may be skipped by passing run_test=false, allowing an
easier use in combination with other test packages.

An lcov file is also produced in `Pkg.dir(pkg, \"$(COVDIR)\", \"$(LCOVINFO)\")`.

See [`report_coverage`](@ref), [`clean_coverage`](@ref).
"""
function generate_coverage(pkg = nothing; run_test = true)
    if run_test
        isnothing(pkg) ? Pkg.test(; coverage = true) : Pkg.test(pkg; coverage = true)
    end
    package_dir = pkgdir(pkg)
    cd(package_dir) do
        coverage = CoverageTools.process_folder()
        mkpath(COVDIR)
        tracefile = joinpath(COVDIR, LCOVINFO)
        CoverageTools.LCOV.writefile(tracefile, coverage)
        CoverageTools.clean_folder("./")
        eval_coverage_metrics(coverage, package_dir)
    end
end

"""
$(SIGNATURES)

Clean up after [`generate_coverage`](@ref).

If `rm_directory`, will delete the coverage directory, otherwise only deletes the
`$(LCOVINFO) file.
"""
function clean_coverage(pkg = nothing; rm_directory::Bool = true)
    cd(pkgdir(pkg)) do
        if rm_directory
            rm(COVDIR; force = true, recursive = true)
        else
            rm(COVDIR, LCOVINFO)
        end
    end
end

format_gap(gap) = length(gap) == 1 ? "$(first(gap))" : "$(first(gap)) - $(last(gap))"
function format_line(summary)
    hcat(
        summary isa PackageCoverage ? "TOTAL" : summary.filename,
        @sprintf("%3d / %3d", summary.lines_hit, summary.lines_tracked),
        isnan(summary.coverage) ? "-" : @sprintf("%3.0f%%", summary.coverage),
        summary isa PackageCoverage ? "" :
        join(map(format_gap, summary.coverage_gaps), ", "),
    )
end

function Base.show(io::IO, coverage::PackageCoverage)
    table = reduce(vcat, map(format_line, [coverage.files..., coverage]))
    row_coverage = [getfield.(coverage.files, :coverage)... coverage.coverage]

    highlighters = (
        Highlighter(
            (data, i, j) -> j == 3 && row_coverage[i] <= 50,
            bold = true,
            foreground = :red,
        ),
        Highlighter((data, i, j) -> j == 3 && row_coverage[i] <= 70, foreground = :yellow),
        Highlighter((data, i, j) -> j == 3 && row_coverage[i] >= 90, foreground = :green),
    )

    pretty_table(
        io,
        table,
        header = ["File name", "Lines hit", "Coverage", "Missing"],
        alignment = [:l, :r, :r, :r],
        crop = :none,
        linebreaks = true,
        columns_width = [min(30, maximum(length.(table[:, 1]))), 11, 8, 35],
        autowrap = true,
        highlighters = highlighters,
        body_hlines = [size(table, 1) - 1],
    )
end

"""
$(SIGNATURES)

Generate, and optionally open, the HTML coverage summary in a browser for `pkg`
inside `dir`.

See [`generate_coverage`](@ref).
"""
function html_coverage(coverage::PackageCoverage; open = false, dir = tempdir())
    cd(coverage.package_dir) do
        branch = try
            LibGit2.headname(GitRepo("./"))
        catch
            @warn "git branch could not be detected"
        end

        title = "on branch $(branch)"
        tracefile = joinpath(COVDIR, LCOVINFO)

        try
            run(`genhtml -t $(title) -o $(dir) $(tracefile)`)
        catch e
            error(
                "Failed to run genhtml. Check that lcov is installed (see the README).",
                "\nError message: ",
                sprint(Base.showerror, e),
            )
        end
        @info("generated coverage HTML")
        open && DefaultApplication.open(joinpath(dir, "index.html"))
    end
    nothing
end

function html_coverage(pkg = nothing; open = false, dir = tempdir())
    html_coverage(generate_coverage(pkg), open = open, dir = dir)
end

"""
$(SIGNATURES)

Utility method that prints coverage statistics and exits with a status code 0 if
the target coverage was met or with a status code 1 otherwise. Useful in command
line, e.g.

```bash
julia --project -e'using LocalCoverage; report_coverage(target_coverage=90)'
```

See [`generate_coverage`](@ref).
"""
function report_coverage(coverage::PackageCoverage, target_coverage = 80)
    was_target_met = coverage.coverage >= target_coverage
    print(" Target coverage ", was_target_met ? "was met" : "wasn't met", " (")
    printstyled("$target_coverage%", color = was_target_met ? :green : :red, bold = true)
    println(")")
    exit(was_target_met ? 0 : 1)
end

function report_coverage(pkg = nothing; target_coverage = 80)
    coverage = generate_coverage(pkg)
    show(coverage)
    report_coverage(coverage, target_coverage)
end

"""
$(SIGNATURES)

Generate a coverage Cobertura XML in the package `coverage` directory.

This requires the Python package `lcov_cobertura` (>= v2.0.1), available in PyPl via
`pip install lcov_cobertura`.
"""
function generate_xml(coverage::PackageCoverage, filename="cov.xml")
    run(Cmd(Cmd(["lcov_cobertura", "lcov.info", "-o", filename]),
            dir = joinpath(coverage.package_dir, COVDIR)))
    @info("generated cobertura XML $filename")
end

end # module
