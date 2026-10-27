// What Claude Code 2.1.310 printed when the probe ran it as the app does (its own configuration
// folder, self-update off), on 2026-10-26, with emails and ids taken out and the folder named as
// the app's. `ClaudeCodeModel` and `ClaudeCode` are tested on these, word for word.

enum ClaudeCodeRecordings {
    /// An answer: Haiku 5.5 at medium effort, asked to reply OK.
    static let answer = #"{"duration_api_ms":639,"stop_reason":"end_turn","session_id":"00000000-0000-0000-0000-000000000000","total_cost_usd":0.0001282,"usage":{"input_tokens":2,"cache_creation_input_tokens":630,"cache_read_input_tokens":0,"output_tokens":4,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":630,"ephemeral_5m_input_tokens":0},"inference_geo":"global","iterations":[{"input_tokens":2,"output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":630,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":630},"type":"message"}],"speed":"standard","fallback_credit":null},"modelUsage":{"claude-haiku-5-5":{"inputTokens":2,"outputTokens":4,"cacheReadInputTokens":0,"cacheCreationInputTokens":630,"webSearchRequests":0,"costUSD":0.0001282,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":0,"canonicalModel":"claude-haiku-5-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"completed","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"safety_stops":0,"is_error":false,"num_turns":1,"subtype":"success","api_error_status":null,"result":"OK","ttft_ms":737,"type":"result","duration_ms":756,"uuid":"00000000-0000-0000-0000-000000000000","ttft_stream_ms":736,"time_to_request_ms":114,"first_content_frame_ms":737,"queued_turn_count":0,"result_index":0}"#

    /// A call made before the app's folder was signed in.
    static let notLoggedIn = #"{"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"00000000-0000-0000-0000-000000000000","total_cost_usd":0,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard","fallback_credit":null},"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"safety_stops":0,"is_error":true,"num_turns":1,"subtype":"success","api_error_status":null,"result":"Not logged in · Please run /login","type":"result","duration_ms":29,"uuid":"00000000-0000-0000-0000-000000000000","queued_turn_count":0,"result_index":0}"#

    /// A call naming a model there isn't.
    static let unknownModel = #"{"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"00000000-0000-0000-0000-000000000000","total_cost_usd":0,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard","fallback_credit":null},"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"safety_stops":0,"is_error":true,"num_turns":1,"subtype":"success","api_error_status":404,"result":"There's an issue with the selected model (claude-nonexistent-9). It may not exist or you may not have access to it. Run --model to pick a different model.","type":"result","duration_ms":835,"uuid":"00000000-0000-0000-0000-000000000000","queued_turn_count":0,"result_index":0}"#

    /// A call whose answer ran past a 40-token limit: Claude Code tried three more times, then failed.
    static let cutOff = #"{"duration_api_ms":7619,"stop_reason":"stop_sequence","session_id":"00000000-0000-0000-0000-000000000000","total_cost_usd":0.0006648,"usage":{"input_tokens":8,"cache_creation_input_tokens":2920,"cache_read_input_tokens":0,"output_tokens":160,"output_tokens_details":{"thinking_tokens":159},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":2920,"ephemeral_5m_input_tokens":0},"inference_geo":"global","iterations":[{"input_tokens":2,"output_tokens":40,"cache_read_input_tokens":0,"cache_creation_input_tokens":823,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":823},"type":"message"}],"speed":"standard","fallback_credit":null},"modelUsage":{"claude-haiku-5-5":{"inputTokens":8,"outputTokens":160,"cacheReadInputTokens":0,"cacheCreationInputTokens":2920,"webSearchRequests":0,"costUSD":0.0006648,"contextWindow":1000000,"maxOutputTokens":128000,"thinkingTokens":159,"canonicalModel":"claude-haiku-5-5","provider":"firstParty","costBasis":"list"}},"permission_denials":[],"terminal_reason":"api_error","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"safety_stops":0,"is_error":true,"num_turns":4,"subtype":"success","api_error_status":null,"api_error":"max_output_tokens","result":"API Error: Claude's response exceeded the 40 output token maximum. To configure this behavior, set the CLAUDE_CODE_MAX_OUTPUT_TOKENS environment variable.","type":"result","duration_ms":7662,"uuid":"00000000-0000-0000-0000-000000000000","queued_turn_count":0,"result_index":0}"#

    /// `claude auth status`, signed in.
    static let signedIn = #"""
    {
      "loggedIn": true,
      "authMethod": "claude.ai",
      "apiProvider": "firstParty",
      "analyticsDisabled": false,
      "projectsDirectory": "/Users/ann/Library/Application Support/InfiniteCanvas/claude-code/projects",
      "configDirectory": "/Users/ann/Library/Application Support/InfiniteCanvas/claude-code",
      "email": "ann@example.com",
      "orgId": "00000000-0000-0000-0000-000000000000",
      "orgName": "ann@example.com's Organization",
      "subscriptionType": "max"
    }
    """#

    /// `claude auth status`, signed out.
    static let signedOut = #"""
    {
      "loggedIn": false,
      "authMethod": "none",
      "apiProvider": "firstParty",
      "analyticsDisabled": false,
      "projectsDirectory": "/Users/ann/Library/Application Support/InfiniteCanvas/claude-code/projects",
      "configDirectory": "/Users/ann/Library/Application Support/InfiniteCanvas/claude-code"
    }
    """#
}
