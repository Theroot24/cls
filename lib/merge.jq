# merge.jq — Claude settings.json의 Stop hook 멱등 upsert/remove.
#
# 사용: jq --arg cmd "<canonical command>" --arg mode "add"|"remove" -f merge.jq settings.json
#   add    → Stop의 matcher=="" 그룹에 정확히 $cmd 1개를 보장(멱등). 다른 hook/이벤트 보존.
#   remove → 모든 Stop 그룹에서 정확히 $cmd 제거. 다른 hook/이벤트 보존.
#
# 식별은 **정확한 명령 문자열 일치**(.command == $cmd)로 한다(substring 금지).
# symlink 전략상 $cmd는 항상 `bash $HOME/.claude/scripts/track-session.sh`로 고정이므로
# stale-path 변형이 없고, 무관한 `/other/track-session.sh` hook을 오인 제거하지 않는다.
# 잘못된 JSON 입력은 jq가 비정상 종료 → 호출측(install)이 원본을 보존한다.

  .hooks //= {}
| .hooks.Stop //= []
| if $mode == "add" then
    ( if ([ .hooks.Stop[] | .matcher // "" ] | index("")) == null
      then .hooks.Stop += [ { "matcher": "", "hooks": [] } ]
      else . end )
    | ( [ .hooks.Stop[] | .matcher // "" ] | index("") ) as $gi
    | .hooks.Stop[$gi].hooks //= []
    | .hooks.Stop[$gi].hooks |= ( map(select((.command // "") != $cmd))
                                  + [ { "type": "command", "command": $cmd, "timeout": 5000 } ] )
  else
    .hooks.Stop |= map( .hooks = ( (.hooks // []) | map(select((.command // "") != $cmd)) ) )
  end
