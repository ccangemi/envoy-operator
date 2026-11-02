# The bundle does not ship the InferencePool CRDs

On clusters with OpenShift AI, KServe owns `inferencepools.inference.networking.k8s.io` and restores its own version; a second owner would keep overwriting it. The agent router works without these CRDs (it skips its InferencePool controller), so the bundle leaves them to OpenShift AI and the bundle gate rejects any `inference.networking.*` CRD.
