if exists("b:current_syntax")
  finish
endif

" Comment lines (lines starting with #)
syntax match timewarriorComment /^#.*/

" Time range at the start of an entry line: HH:MM-HH:MM or HH:MM-
" Contained so it only fires on entry lines, not comment lines.
syntax match timewarriorTime /^\d\{2}:\d\{2}-\(\d\{2}:\d\{2}\)\?/ contained
syntax match timewarriorEntry /^\d\{2}:\d\{2}-[^\n]*/ contains=timewarriorTime

highlight default link timewarriorComment Comment
highlight default link timewarriorTime    Number

let b:current_syntax = "timewarrior"
