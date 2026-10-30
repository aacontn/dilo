/// Transcripciones de stream-json grabadas de la CLI `claude` 2.1.309 el
/// 2026-10-30, con prompts triviales y Haiku 5.5 en carpetas de prueba de
/// `/Volumes/SSD2`. Se recortaron los campos que no se leen (la lista de
/// herramientas y servidores del `init`, el uso de tokens, las firmas del
/// pensamiento) para no versionar la configuración de nadie; el resto es lo
/// que escribió la CLI, en su orden.
enum GrabacionesDeClaudeCode {
  /// Dos turnos en la misma sesión: Claude pide correr `touch prueba.txt`, se
  /// aprueba y lo corre; después pide `rm prueba.txt`, se niega y lo dice.
  static let permitirYNegar: [String] = [
    #"{"type":"system","subtype":"init","cwd":"/Volumes/SSD2/claude-code-pruebas/p1","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a","model":"claude-haiku-5-5","permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.309","tools":["Bash","Edit","Read","Write"]}"#,
    #"{"type":"system","subtype":"commands_changed","commands":[]}"#,
    #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgXhwm3WXjnhSzbNvY4ej","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_016s8mJFX7bwYASZTUV97FRK","name":"Bash","input":{"command":"touch prueba.txt","description":"Create empty file prueba.txt in current folder"}}]},"parent_tool_use_id":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"system","subtype":"task_summary","detail":"Creating empty file prueba.txt in current folder","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"control_request","request_id":"c0457625-2640-4318-8870-7f8d5658895a","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch prueba.txt","description":"Create empty file prueba.txt in current folder"},"description":"Create empty file prueba.txt in current folder","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch prueba.txt"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/Volumes/SSD2/claude-code-pruebas/p1"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}],"blocked_path":"/Volumes/SSD2/claude-code-pruebas/p1/prueba.txt","tool_use_id":"toolu_016s8mJFX7bwYASZTUV97FRK"}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_016s8mJFX7bwYASZTUV97FRK","type":"tool_result","content":"(Bash completed with no output)","is_error":false}]},"parent_tool_use_id":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a","tool_use_result":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":true}}"#,
    #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgXhwya51CUcZPeejCUL9","type":"message","role":"assistant","content":[{"type":"text","text":"Listo: ejecuté `touch prueba.txt` con la herramienta Bash en la carpeta de trabajo, y el comando terminó sin errores ni salida."}]},"parent_tool_use_id":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"system","subtype":"post_turn_summary","status_detail":"ran touch prueba.txt via Bash; no errors","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"result","subtype":"success","is_error":false,"duration_ms":7346,"num_turns":2,"result":"Listo: ejecuté `touch prueba.txt` con la herramienta Bash en la carpeta de trabajo, y el comando terminó sin errores ni salida.","stop_reason":"end_turn","terminal_reason":"completed","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a","total_cost_usd":0.01478303,"permission_denials":[]}"#,
    #"{"type":"system","subtype":"task_summary","detail":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"system","subtype":"init","cwd":"/Volumes/SSD2/claude-code-pruebas/p1","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a","model":"claude-haiku-5-5","permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.309","tools":["Bash","Edit","Read","Write"]}"#,
    #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgXhxEeSb42SvDCcbjPxe","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01PY1Q5WDj6d8pZupWk6FgTt","name":"Bash","input":{"command":"rm prueba.txt","description":"Delete file prueba.txt in current folder"}}]},"parent_tool_use_id":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"system","subtype":"task_summary","detail":"Deleting file prueba.txt in current folder","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"control_request","request_id":"7e151cac-62c9-495e-a100-9a0fbc8a7458","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"rm prueba.txt","description":"Delete file prueba.txt in current folder"},"description":"Delete file prueba.txt in current folder","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm prueba.txt"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/Volumes/SSD2/claude-code-pruebas/p1"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}],"blocked_path":"/Volumes/SSD2/claude-code-pruebas/p1/prueba.txt","tool_use_id":"toolu_01PY1Q5WDj6d8pZupWk6FgTt"}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"La persona dijo que no.","is_error":true,"tool_use_id":"toolu_01PY1Q5WDj6d8pZupWk6FgTt"}]},"parent_tool_use_id":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a","tool_use_result":"Error: La persona dijo que no."}"#,
    #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":230,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgXhxNicFRRoFjt4Uvqku","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"…"}]},"parent_tool_use_id":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgXhxNicFRRoFjt4Uvqku","type":"message","role":"assistant","content":[{"type":"text","text":"Me lo negaron: el `rm prueba.txt` fue rechazado, así que el archivo sigue ahí."}]},"parent_tool_use_id":null,"session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"system","subtype":"post_turn_summary","status_detail":"rm prueba.txt was denied; file still present","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a"}"#,
    #"{"type":"result","subtype":"success","is_error":false,"duration_ms":6703,"num_turns":2,"result":"Me lo negaron: el `rm prueba.txt` fue rechazado, así que el archivo sigue ahí.","stop_reason":"end_turn","terminal_reason":"completed","session_id":"78e26841-aa02-42fe-82ea-2d9495a76d0a","total_cost_usd":0.01710809,"permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_01PY1Q5WDj6d8pZupWk6FgTt","tool_input":{"command":"rm prueba.txt","description":"Delete file prueba.txt in current folder"}}]}"#,
  ]

  /// Un turno largo interrumpido a los seis segundos (`control_request`
  /// `interrupt`) y un turno siguiente en la misma sesión.
  static let interrumpida: [String] = [
    #"{"type":"system","subtype":"init","cwd":"/Volumes/SSD2/claude-code-pruebas/p2","session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b","model":"claude-haiku-5-5","permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.309","tools":["Bash","Edit","Read","Write"]}"#,
    #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"system","subtype":"commands_changed","commands":[]}"#,
    #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":300,"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"control_response","response":{"subtype":"success","request_id":"req_int","response":{"still_queued":[]}}}"#,
    #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null,"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":3719,"num_turns":2,"stop_reason":null,"terminal_reason":"aborted_streaming","session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b","total_cost_usd":0,"permission_denials":[],"errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"]}"#,
    #"{"type":"system","subtype":"init","cwd":"/Volumes/SSD2/claude-code-pruebas/p2","session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b","model":"claude-haiku-5-5","permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.309","tools":["Bash","Edit","Read","Write"]}"#,
    #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":247,"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgXhzco1FghG652avqFw2","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"…"}]},"parent_tool_use_id":null,"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"msg_011CgXhzco1FghG652avqFw2","type":"message","role":"assistant","content":[{"type":"text","text":"cebolla"}]},"parent_tool_use_id":null,"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"system","subtype":"post_turn_summary","status_detail":"repeated the secret word as requested: cebolla","session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b"}"#,
    #"{"type":"result","subtype":"success","is_error":false,"duration_ms":4440,"num_turns":1,"result":"cebolla","stop_reason":"end_turn","terminal_reason":"completed","session_id":"5d31e461-2e86-47c8-a5f4-82496267ce4b","total_cost_usd":0.00895165,"permission_denials":[]}"#,
  ]

  /// `--resume` con un id que no existe: la CLI escribe el error en stderr,
  /// un `result` con `errors` y sale con 1.
  static let retomarUnaQueNoExiste: [String] = [
    #"{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":0,"num_turns":0,"stop_reason":null,"session_id":"00000000-0000-4000-8000-000000000000","total_cost_usd":0,"permission_denials":[],"errors":["No conversation found with session ID: 00000000-0000-4000-8000-000000000000"]}"#,
  ]
}
