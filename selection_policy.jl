module SelectionPolicy

export RECALL_MIN_LOCAL_SCORE, SCORE_POLICY_VERSION, recall_approval_supported

const SCORE_POLICY_VERSION = "human-feedback-v1"

const RECALL_MIN_LOCAL_SCORE = something(
    tryparse(Float64, get(ENV, "RECALL_MIN_LOCAL_SCORE", "0.05")),
    0.05,
)

# Broad aggregators such as arXiv and bioRxiv are already screened by topic.
# Physics/optics journals need an additional biological signal before a
# recall-focused AI pass may overturn the precision-focused first pass.
const RECALL_RESTRICTED_SOURCES = Set([
    "optica",
    "optical materials express",
    "optics express",
    "optics letters",
    "prl",
    "prr",
    "prx",
])

const BIOPHYSICAL_SIGNAL = r"\b(?:bio\w*|cell\w*|tissue\w*|protein\w*|peptide\w*|dna|rna|membrane\w*|microscop\w*|imag(?:e|ing)\w*|organism\w*|bacter\w*|virus\w*|neuron\w*|muscle\w*|medical\w*|clinical\w*)\b"i

field_text(record, field::Symbol)::String = strip(string(get(record, field, "")))

function recall_approval_supported(paper, local_score::Real)::Bool
    local_score >= RECALL_MIN_LOCAL_SCORE || return false
    source = lowercase(field_text(paper, :source))
    source in RECALL_RESTRICTED_SOURCES || return true
    text = field_text(paper, :title) * " " * field_text(paper, :abstract)
    return occursin(BIOPHYSICAL_SIGNAL, text)
end

end
