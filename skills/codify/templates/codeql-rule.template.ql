/**
 * @name {{rule_name_human}}
 * @description {{one_line_what_this_catches}}. Source: {{finding_id}}.
 * @kind path-problem
 * @problem.severity error
 * @security-severity {{0.0-10.0}}
 * @precision high
 * @id {{language}}/{{rule_id_kebab}}
 * @tags security
 *       external/cwe/{{CWE-id-lower}}
 *       source-finding/{{finding_id}}
 */

import {{language_capitalized}}
// import the language-specific data-flow library, e.g.:
// import semmle.code.java.dataflow.TaintTracking
// import semmle.code.python.dataflow.new.TaintTracking
// import javascript

module {{ModuleName}}Config implements DataFlow::ConfigSig {
  // A taint source: where untrusted input enters. Tighten to the
  // exact framework primitive used in this codebase (Flask request,
  // Express req, Spring @RequestParam, etc.).
  predicate isSource(DataFlow::Node node) {
    {{source_predicate}}
  }

  // A taint sink: the dangerous primitive the finding identified.
  // Keep this *narrow* — overly broad sinks generate noise that
  // gets the rule turned off.
  predicate isSink(DataFlow::Node node) {
    {{sink_predicate}}
  }

  // Optional sanitizer: the codebase's safe-by-default helper.
  // Including this prevents the rule firing on already-fixed call
  // sites and on the recommended remediation pattern.
  predicate isBarrier(DataFlow::Node node) {
    {{barrier_predicate_optional}}
  }
}

module {{ModuleName}}Flow = TaintTracking::Global<{{ModuleName}}Config>;

from {{ModuleName}}Flow::PathNode source, {{ModuleName}}Flow::PathNode sink
where {{ModuleName}}Flow::flowPath(source, sink)
select sink.getNode(), source, sink,
  "{{category}}: tainted input from $@ flows to $@.",
  source.getNode(), "source", sink.getNode(), "sink"
