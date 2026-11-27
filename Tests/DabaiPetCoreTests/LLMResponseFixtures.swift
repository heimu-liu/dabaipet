import Foundation

// Synthetic, non-streaming payloads shaped like the four vendors' public responses.
enum LLMResponseFixtures {
    static let openAI = Data(#"{"id":"chatcmpl-fixture","object":"chat.completion","created":1,"model":"gpt-test","choices":[{"index":0,"message":{"role":"assistant","content":"[happy] OK","refusal":null},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":3,"total_tokens":11}}"#.utf8)
    static let deepSeek = Data(#"{"id":"fixture","object":"chat.completion","created":1,"model":"deepseek-reasoner","choices":[{"index":0,"message":{"role":"assistant","reasoning_content":"hidden fixture","content":"[care] OK"},"finish_reason":"stop"}],"usage":{"completion_tokens_details":{"reasoning_tokens":2}}}"#.utf8)
    static let ollama = Data(#"{"id":"chatcmpl-1","object":"chat.completion","created":1,"model":"local-model","system_fingerprint":"fp_ollama","choices":[{"index":0,"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#.utf8)
    static let anthropic = Data(#"{"id":"msg_fixture","type":"message","role":"assistant","model":"claude-test","content":[{"type":"thinking","thinking":"hidden fixture","signature":"fixture"},{"type":"text","text":"[happy]"},{"type":"text","text":"OK"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":8,"output_tokens":3}}"#.utf8)
    static let models = Data(#"{"data":[{"id":"fixture-model"}]}"#.utf8)
}
