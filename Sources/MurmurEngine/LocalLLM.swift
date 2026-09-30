import Foundation
import llama

public enum LocalLLMError: LocalizedError {
    case modelLoadFailed(String)
    case contextFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    case promptTooLong(Int)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): "Couldn't load the AI model at \(path)."
        case .contextFailed: "Couldn't create the AI model context."
        case .tokenizeFailed: "Couldn't tokenize the prompt."
        case .decodeFailed(let code): "The AI model failed while generating (code \(code))."
        case .promptTooLong(let n): "The text is too long for the AI editor (\(n) tokens)."
        }
    }
}

public struct GenerationStats: Sendable {
    public var promptTokens: Int
    public var reusedTokens: Int
    public var generatedTokens: Int
    public var draftAccepted: Int
    public var seconds: Double
}

/// Minimal llama.cpp runner with KV-cache prefix reuse and prompt-lookup speculative decoding.
///
/// The editing prompts share a long fixed prefix (instructions + examples), so reusing the cache
/// makes each call only pay for the new transcript. Because edited text mostly copies the input,
/// drafting tokens from the input and verifying them in one batch speeds up generation a lot.
public final class LocalLLM: @unchecked Sendable {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let lock = NSLock()
    private var cached: [llama_token] = []
    public let contextLength: Int
    public let path: String

    private static let backendOnce: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    public init(path: String, contextLength: Int = 4096) throws {
        _ = Self.backendOnce
        self.path = path
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(path, mparams) else { throw LocalLLMError.modelLoadFailed(path) }
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextLength)
        cparams.n_batch = 512
        cparams.n_ubatch = 512
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        cparams.no_perf = true
        guard let context = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LocalLLMError.contextFailed
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextLength = contextLength
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        self.sampler = chain
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    // MARK: - Tokens

    public func tokenize(_ text: String, addSpecial: Bool = true) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let byteCount = Int32(utf8.count - 1)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        var n = llama_tokenize(vocab, utf8, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, utf8, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard n >= 0 else { throw LocalLLMError.tokenizeFailed }
        return Array(tokens.prefix(Int(n)))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Generation

    /// Greedy generation. `draftSource` is text the output is expected to copy from (enables speculative decoding).
    public func generate(prompt: String, maxTokens: Int, stop: [String] = [], draftSource: String? = nil) throws -> (text: String, stats: GenerationStats) {
        lock.lock()
        defer { lock.unlock() }
        let start = Date()
        let promptTokens = try tokenize(prompt)
        guard promptTokens.count + maxTokens < contextLength else { throw LocalLLMError.promptTooLong(promptTokens.count) }

        // Reuse the longest shared prefix already in the KV cache.
        var common = 0
        while common < min(cached.count, promptTokens.count) && cached[common] == promptTokens[common] { common += 1 }
        common = min(common, promptTokens.count - 1)
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
            llama_memory_clear(memory, true)
            common = 0
        }
        cached = Array(promptTokens.prefix(common))

        // Evaluate the new part of the prompt in chunks; logits only for the last token.
        var index = common
        while index < promptTokens.count {
            let end = min(index + 512, promptTokens.count)
            try decode(Array(promptTokens[index..<end]), startPos: index, logitsForAll: false)
            cached.append(contentsOf: promptTokens[index..<end])
            index = end
        }

        let draftTokens = try draftSource.map { try tokenize($0, addSpecial: false) } ?? []
        var output: [llama_token] = []
        var bytes: [UInt8] = []
        var accepted = 0
        var stopHit = false

        var next = llama_sampler_sample(sampler, context, -1)
        generation: while output.count < maxTokens {
            if llama_vocab_is_eog(vocab, next) { break }
            output.append(next)
            bytes.append(contentsOf: piece(next))
            if !stop.isEmpty, let text = String(bytes: bytes, encoding: .utf8), stop.contains(where: { text.contains($0) }) {
                stopHit = true
                break
            }

            // Draft: find where the recent output occurs in the source and propose what follows it.
            let draft = proposeDraft(output: output, source: draftTokens, maxDraft: 12)
            if draft.isEmpty {
                try decode([next], startPos: cached.count, logitsForAll: false)
                cached.append(next)
                next = llama_sampler_sample(sampler, context, -1)
                continue
            }

            // Verify [next] + draft in one batch; logits at every position.
            let batch = [next] + draft
            let base = cached.count
            try decode(batch, startPos: base, logitsForAll: true)
            cached.append(contentsOf: batch)
            var i = 0
            while true {
                let predicted = llama_sampler_sample(sampler, context, Int32(i))
                if i < draft.count && predicted == draft[i] {
                    // Draft token confirmed; it becomes part of the output.
                    if llama_vocab_is_eog(vocab, predicted) { break generation }
                    output.append(predicted)
                    bytes.append(contentsOf: piece(predicted))
                    accepted += 1
                    i += 1
                    if output.count >= maxTokens { break generation }
                    continue
                }
                // Mismatch (or draft exhausted): drop unverified draft tokens from the cache.
                let keep = base + 1 + i
                if keep < cached.count {
                    _ = llama_memory_seq_rm(memory, 0, Int32(keep), -1)
                    cached.removeLast(cached.count - keep)
                }
                next = predicted
                break
            }
            if !stop.isEmpty, let text = String(bytes: bytes, encoding: .utf8), stop.contains(where: { text.contains($0) }) {
                stopHit = true
                break
            }
        }

        var text = String(decoding: bytes, as: UTF8.self)
        if stopHit, let s = stop.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            text = String(text[..<s.lowerBound])
        }
        let stats = GenerationStats(promptTokens: promptTokens.count, reusedTokens: common, generatedTokens: output.count,
                                    draftAccepted: accepted, seconds: Date().timeIntervalSince(start))
        return (text, stats)
    }

    private func proposeDraft(output: [llama_token], source: [llama_token], maxDraft: Int) -> [llama_token] {
        guard !source.isEmpty, !output.isEmpty else { return [] }
        // Try the longest suffix of the output (up to 3 tokens) that appears in the source.
        for n in stride(from: min(3, output.count), through: 1, by: -1) {
            let suffix = Array(output.suffix(n))
            var j = source.count - n
            // Prefer the latest match at or after the region we've probably reached.
            var best: Int?
            while j >= 0 {
                if Array(source[j..<(j + n)]) == suffix { best = j; break }
                j -= 1
            }
            if let b = best {
                let startDraft = b + n
                if startDraft < source.count {
                    return Array(source[startDraft..<min(source.count, startDraft + maxDraft)])
                }
            }
        }
        return []
    }

    private func decode(_ tokens: [llama_token], startPos: Int, logitsForAll: Bool) throws {
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (i, t) in tokens.enumerated() {
            batch.token[i] = t
            batch.pos[i] = llama_pos(startPos + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (logitsForAll || i == tokens.count - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        let rc = llama_decode(context, batch)
        if rc != 0 { throw LocalLLMError.decodeFailed(rc) }
    }

    /// Clears the cache (e.g. after a failure) so the next call starts clean.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        llama_memory_clear(llama_get_memory(context), true)
        cached = []
    }
}
