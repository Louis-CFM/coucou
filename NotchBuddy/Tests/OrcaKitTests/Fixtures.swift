// Sanitized captures of real `orca ... --json` output (Orca 1.4.233, 2026-10-21).
// Names/paths/ids/prompts/emails replaced; a few rows are synthetic variants of real rows
// (waiting agent, old unread, remote host, long message, archived) to cover derivation rules.
// Sentinel strings (*-DO-NOT-LEAK) must never appear in the exposed model.

enum Fixtures {
    static let worktreePs = #"""
{
 "_meta": {
  "runtimeId": "003f5ab9-9915-4a3b-b9de-e4e1b31c0f75"
 },
 "id": "fixture",
 "ok": true,
 "result": {
  "hostScope": {
   "hostIds": [
    "local"
   ],
   "omittedHostIds": [
    "runtime:9e98748e-b2d3-4b17-a702-d0ca9664ceff",
    "runtime:c59166e9-e6f3-4fa9-902c-00e9b9ed9043"
   ],
   "omittedHostSelectors": [
    {
     "hostId": "runtime:9e98748e-b2d3-4b17-a702-d0ca9664ceff",
     "selector": "--environment CachyOS"
    },
    {
     "hostId": "runtime:c59166e9-e6f3-4fa9-902c-00e9b9ed9043",
     "selector": "--environment Winboat"
    }
   ]
  },
  "totalCount": 15,
  "truncated": false,
  "worktrees": [
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:0",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "working",
      "stateStartedAt": 1792610531330,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": "Bash",
      "updatedAt": 1792610590433
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "defaultBranch": true,
    "displayName": "main",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792610405994,
    "lastOutputAt": 1792610612817,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 2,
    "parentWorktreeId": null,
    "path": "/redacted/main",
    "preview": "redacted preview",
    "repo": "orca-monitor",
    "repoId": "repo-245",
    "sortOrder": 1792610589676,
    "status": "working",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-245::/redacted/main",
    "worktreeInstanceId": "instance-0"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:1",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "working",
      "stateStartedAt": 1792610574541,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": "Bash",
      "updatedAt": 1792610582417
     }
    ],
    "branch": "refs/heads/henriquefps/strip-rebrand",
    "childWorktreeIds": [],
    "comment": "",
    "createdAt": 1792610570805,
    "creatorProvenance": {
     "kind": "host"
    },
    "defaultBranch": false,
    "displayName": "strip-rebrand",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": false,
    "isPinned": false,
    "lastActivityAt": 1792610570805,
    "lastOutputAt": 1792610612807,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 1,
    "parentWorktreeId": null,
    "path": "/redacted/strip-rebrand",
    "preview": "redacted preview",
    "repo": "orca-notch",
    "repoId": "repo-9",
    "sortOrder": 1792610590676,
    "status": "working",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-9::/redacted/strip-rebrand",
    "worktreeInstanceId": "instance-1"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:2",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "working",
      "stateStartedAt": 1792610588476,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": "Bash",
      "updatedAt": 1792610612189
     }
    ],
    "branch": "refs/heads/henriquefps/orcakit",
    "childWorktreeIds": [],
    "comment": "",
    "createdAt": 1792610584420,
    "creatorProvenance": {
     "kind": "host"
    },
    "defaultBranch": false,
    "displayName": "orcakit",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": false,
    "isPinned": false,
    "lastActivityAt": 1792610584420,
    "lastOutputAt": 1792610612733,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 1,
    "parentWorktreeId": null,
    "path": "/redacted/orcakit",
    "preview": "redacted preview",
    "repo": "orca-notch",
    "repoId": "repo-9",
    "sortOrder": 1792610591676,
    "status": "working",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-9::/redacted/orcakit",
    "worktreeInstanceId": "instance-2"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:3",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792585039565,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792585039565
     },
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": "Short assistant message",
      "paneKey": "pane:3",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792610449195,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": "Read",
      "updatedAt": 1792610449195
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "main",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": true,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792610450700,
    "lastOutputAt": 1792610612350,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 3,
    "parentWorktreeId": null,
    "path": "/redacted/main",
    "preview": "redacted preview",
    "repo": "animator",
    "repoId": "repo-859",
    "sortOrder": 1792610592676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-859::/redacted/main",
    "worktreeInstanceId": "instance-3"
   },
   {
    "agents": [],
    "branch": "refs/heads/master",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "master",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792246863275,
    "lastOutputAt": 1792610266781,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 1,
    "parentWorktreeId": null,
    "path": "/redacted/master",
    "preview": "redacted preview",
    "repo": "kindle-apps",
    "repoId": "repo-115",
    "sortOrder": 1792610570676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-115::/redacted/master",
    "worktreeInstanceId": "instance-4"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:5",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792412740589,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792412741580
     },
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:5",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792412740594,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792412741564
     },
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:5",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792412779296,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792412779296
     },
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": "Short assistant message",
      "paneKey": "pane:5",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792596835045,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792596835045
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "main",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792596572690,
    "lastOutputAt": 1792609183271,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 4,
    "parentWorktreeId": null,
    "path": "/redacted/main",
    "preview": "redacted preview",
    "repo": "writting-assistant",
    "repoId": "repo-922",
    "sortOrder": 1792610587676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "completed",
    "worktreeId": "repo-922::/redacted/main",
    "worktreeInstanceId": "instance-5"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": "Short assistant message",
      "paneKey": "pane:6",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792543806851,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": "Bash",
      "updatedAt": 1792543806851
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "main",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792543808356,
    "lastOutputAt": 1792592606130,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 2,
    "parentWorktreeId": null,
    "path": "/redacted/main",
    "preview": "redacted preview",
    "repo": "stagecast",
    "repoId": "repo-959",
    "sortOrder": 1792610586676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "todo",
    "worktreeId": "repo-959::/redacted/main",
    "worktreeInstanceId": "instance-6"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:7",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792412002569,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792412004050
     },
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:7",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792412002582,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792412004000
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "main",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792183477016,
    "lastOutputAt": null,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 4,
    "parentWorktreeId": null,
    "path": "/redacted/main",
    "preview": "redacted preview",
    "repo": "tortola-ventures",
    "repoId": "repo-713",
    "sortOrder": 1792610569676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-review",
    "worktreeId": "repo-713::/redacted/main",
    "worktreeInstanceId": "instance-7"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": "Short assistant message",
      "paneKey": "pane:8",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792442106961,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792442106961
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "requests",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1791467744197,
    "lastOutputAt": null,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 3,
    "parentWorktreeId": null,
    "path": "/redacted/requests",
    "preview": "redacted preview",
    "repo": "requests",
    "repoId": "repo-892",
    "sortOrder": 1792610562676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-892::/redacted/requests",
    "worktreeInstanceId": "instance-8"
   },
   {
    "agents": [],
    "branch": "refs/heads/henriquefps/ctx-1m-b",
    "childWorktreeIds": [],
    "comment": "",
    "createdAt": 1792517834862,
    "creatorProvenance": {
     "kind": "host"
    },
    "defaultBranch": false,
    "displayName": "ctx-1m-b",
    "hasAttachedPty": false,
    "hasHostSidebarActivity": false,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": false,
    "isPinned": false,
    "lastActivityAt": 1792517984327,
    "lastOutputAt": null,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": {
     "number": 46,
     "state": "open",
     "title": "redacted title",
     "url": "https://example.invalid/pr"
    },
    "liveTerminalCount": 0,
    "parentWorktreeId": null,
    "path": "/redacted/ctx-1m-b",
    "preview": "redacted preview",
    "repo": "animator",
    "repoId": "repo-859",
    "sortOrder": 1792610579676,
    "status": "inactive",
    "terminalPlatform": "darwin",
    "terminalVerdict": "none",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-859::/redacted/ctx-1m-b",
    "worktreeInstanceId": "instance-9"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": "Short assistant message",
      "paneKey": "pane:10",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "waiting-permission",
      "stateStartedAt": 1792543806851,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": "Bash",
      "updatedAt": 1792543806851
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "needs-input",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792610000000,
    "lastOutputAt": 1792592606130,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 2,
    "parentWorktreeId": null,
    "path": "/redacted/needs-input",
    "preview": "redacted preview",
    "repo": "stagecast",
    "repoId": "repo-959",
    "sortOrder": 1792610586676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "todo",
    "worktreeId": "repo-959::/redacted/needs-input",
    "worktreeInstanceId": "instance-10"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": "Short assistant message",
      "paneKey": "pane:11",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792442106961,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792442106961
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "old-unread",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1791467744197,
    "lastOutputAt": null,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 3,
    "parentWorktreeId": null,
    "path": "/redacted/old-unread",
    "preview": "redacted preview",
    "repo": "requests",
    "repoId": "repo-892",
    "sortOrder": 1792610562676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": true,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-892::/redacted/old-unread",
    "worktreeInstanceId": "instance-11"
   },
   {
    "agents": [],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "remote-box",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "ssh:devbox",
    "isActive": false,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792610100000,
    "lastOutputAt": 1792610565930,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 1,
    "parentWorktreeId": null,
    "path": "/redacted/remote-box",
    "preview": "redacted preview",
    "repo": "orca-notch",
    "repoId": "repo-9",
    "sortOrder": 1792610588676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-9::/redacted/remote-box",
    "worktreeInstanceId": "instance-12"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": "LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL",
      "paneKey": "pane:13",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "done",
      "stateStartedAt": 1792585039565,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": null,
      "updatedAt": 1792585039565
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "fresh-unread",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": true,
    "isArchived": false,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792610450700,
    "lastOutputAt": 1792610612350,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 3,
    "parentWorktreeId": null,
    "path": "/redacted/fresh-unread",
    "preview": "redacted preview",
    "repo": "animator",
    "repoId": "repo-859",
    "sortOrder": 1792610592676,
    "status": "active",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": true,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-859::/redacted/fresh-unread",
    "worktreeInstanceId": "instance-13"
   },
   {
    "agents": [
     {
      "agentType": "claude",
      "displayName": "redacted",
      "interrupted": false,
      "lastAssistantMessage": null,
      "paneKey": "pane:14",
      "parentPaneKey": null,
      "programStatus": null,
      "prompt": "SECRET-PROMPT-DO-NOT-LEAK",
      "state": "working",
      "stateStartedAt": 1792610531330,
      "taskTitle": "redacted",
      "toolInput": "SECRET-TOOLINPUT-DO-NOT-LEAK",
      "toolName": "Bash",
      "updatedAt": 1792610590433
     }
    ],
    "branch": "refs/heads/main",
    "childWorktreeIds": [],
    "comment": "",
    "defaultBranch": true,
    "displayName": "archived-one",
    "hasAttachedPty": true,
    "hasHostSidebarActivity": true,
    "hostId": "local",
    "isActive": false,
    "isArchived": true,
    "isMainWorktree": true,
    "isPinned": false,
    "lastActivityAt": 1792610405994,
    "lastOutputAt": 1792610612817,
    "linkedGitLabIssue": null,
    "linkedGitLabMR": null,
    "linkedIssue": null,
    "linkedItems": [],
    "linkedLinearIssue": null,
    "linkedPR": null,
    "liveTerminalCount": 2,
    "parentWorktreeId": null,
    "path": "/redacted/archived-one",
    "preview": "redacted preview",
    "repo": "orca-monitor",
    "repoId": "repo-245",
    "sortOrder": 1792610589676,
    "status": "working",
    "terminalPlatform": "darwin",
    "terminalVerdict": "live",
    "unread": false,
    "unverifiableTerminalCount": 0,
    "workspaceKind": "git",
    "workspaceStatus": "in-progress",
    "worktreeId": "repo-245::/redacted/archived-one",
    "worktreeInstanceId": "instance-14"
   }
  ]
 }
}
"""#
    static let accountList = #"""
{
 "_meta": {
  "runtimeId": "003f5ab9-9915-4a3b-b9de-e4e1b31c0f75"
 },
 "id": "fixture",
 "ok": true,
 "result": {
  "claude": {
   "accounts": [
    {
     "email": "secret.user@example.com",
     "id": "ACCOUNT-ID-DO-NOT-LEAK",
     "organizationName": "Secret Org",
     "organizationUuid": "ORG-UUID-DO-NOT-LEAK"
    }
   ],
   "activeAccountId": "ACCOUNT-ID-DO-NOT-LEAK"
  },
  "rateLimits": {
   "antigravity": {
    "buckets": [
     {
      "group": "Gemini Models",
      "name": "Gemini Models",
      "resetDescription": null,
      "resetsAt": 1793215311000,
      "usedPercent": 0,
      "windowMinutes": 10080,
      "windowName": "Weekly Limit Remaining"
     },
     {
      "group": "Claude and GPT models",
      "name": "Claude and GPT models",
      "resetDescription": null,
      "resetsAt": 1793215311000,
      "usedPercent": 0,
      "windowMinutes": 10080,
      "windowName": "Weekly Limit Remaining"
     }
    ],
    "error": null,
    "provider": "antigravity",
    "session": null,
    "status": "ok",
    "updatedAt": 1792610511995,
    "usageMetadata": {
     "attemptedSources": [
      "cli"
     ],
     "credentialSource": "antigravity-cli",
     "lastSuccessfulSource": "cli",
     "source": "cli"
    },
    "weekly": {
     "resetDescription": null,
     "resetsAt": 1793215311000,
     "usedPercent": 0,
     "windowMinutes": 10080
    }
   },
   "claude": {
    "error": null,
    "fableWeekly": null,
    "provider": "claude",
    "session": {
     "resetDescription": "9:10 PM",
     "resetsAt": 1792627800000,
     "usedPercent": 2,
     "windowMinutes": 300
    },
    "status": "ok",
    "updatedAt": 1792610591894,
    "usageMetadata": {
     "source": "live-session"
    },
    "weekly": {
     "resetDescription": "Sun 4:00 PM",
     "resetsAt": 1792954800000,
     "usedPercent": 92,
     "windowMinutes": 10080
    }
   },
   "codex": {
    "error": "Codex CLI not found",
    "provider": "codex",
    "rateLimitResetCredits": {
     "availableCount": 0,
     "credits": [],
     "nextExpiresAt": null,
     "totalEarnedCount": 0
    },
    "session": null,
    "status": "unavailable",
    "updatedAt": 1792610505369,
    "weekly": null
   },
   "someFlag": false
  }
 }
}
"""#
    static let workersPage1 = #"""
{
 "id": "fixture",
 "ok": true,
 "result": {
  "counts": {
   "active": 2
  },
  "page": {
   "hasMore": true,
   "limit": 6,
   "nextCursor": "CURSOR-PAGE-2",
   "total": 8
  },
  "scope": {
   "source": "all"
  },
  "warnings": [],
  "workers": [
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_a1",
    "dispatchStatus": "dispatched",
    "projection": {
     "attention": {
      "categories": [],
      "requiresAction": false
     },
     "dispatchId": "ctx_a1",
     "evidence": {
      "durable": true,
      "lastObservedAt": 1792610612189,
      "liveStatus": "fresh"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_a1",
     "liveness": {
      "observedAt": 1792610612189,
      "source": "agent_status",
      "verdict": "live"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "in_progress",
     "parent": null,
     "provider": {
      "id": "claude",
      "model": null
     },
     "resource": {
      "state": "owned"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "working",
      "detail": "input_accepted",
      "dispatch": "dispatched",
      "worker": "ready"
     },
     "taskId": "task_a1",
     "workspace": {
      "id": "repo-9::/redacted/strip-rebrand",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "owned"
    },
    "runId": "run_redacted",
    "taskId": "task_a1",
    "terminalState": "active",
    "workerState": "ready"
   },
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_a2",
    "dispatchStatus": "dispatched",
    "projection": {
     "attention": {
      "categories": [],
      "requiresAction": false
     },
     "dispatchId": "ctx_a2",
     "evidence": {
      "durable": true,
      "lastObservedAt": 1792610582417,
      "liveStatus": "fresh"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_a2",
     "liveness": {
      "observedAt": 1792610582417,
      "source": "agent_status",
      "verdict": "live"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "in_progress",
     "parent": null,
     "provider": {
      "id": "claude",
      "model": null
     },
     "resource": {
      "state": "owned"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "working",
      "detail": "input_accepted",
      "dispatch": "dispatched",
      "worker": "ready"
     },
     "taskId": "task_a2",
     "workspace": {
      "id": "repo-9::/redacted/orcakit",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "owned"
    },
    "runId": "run_redacted",
    "taskId": "task_a2",
    "terminalState": "active",
    "workerState": "ready"
   },
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_f1",
    "dispatchStatus": "failed",
    "projection": {
     "attention": {
      "categories": [
       "failure",
       "interruption",
       "unverifiable"
      ],
      "requiresAction": true
     },
     "dispatchId": "ctx_f1",
     "evidence": {
      "durable": true,
      "lastObservedAt": null,
      "liveStatus": "unavailable"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_f1",
     "liveness": {
      "reason": "missing_status",
      "verdict": "unverifiable"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "failed",
     "parent": null,
     "provider": null,
     "resource": {
      "state": "user_owned"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "unknown",
      "detail": "abandoned",
      "dispatch": "failed",
      "worker": "abandoned"
     },
     "taskId": "task_f1",
     "workspace": {
      "id": "repo-713::/redacted/main",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "user_owned"
    },
    "runId": "run_redacted",
    "taskId": "task_f1",
    "terminalState": "retained",
    "workerState": "abandoned"
   },
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_s1",
    "dispatchStatus": "completed",
    "projection": {
     "attention": {
      "categories": [
       "root_completion"
      ],
      "requiresAction": false
     },
     "dispatchId": "ctx_s1",
     "evidence": {
      "durable": true,
      "lastObservedAt": null,
      "liveStatus": "unavailable"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_s1",
     "liveness": {
      "source": "resource_release",
      "verdict": "exited"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "succeeded",
     "parent": null,
     "provider": null,
     "resource": {
      "state": "released"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "unknown",
      "detail": "settled",
      "dispatch": "completed",
      "worker": "succeeded"
     },
     "taskId": "task_s1",
     "workspace": {
      "id": "repo-922::/redacted/main",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "released"
    },
    "runId": "run_redacted",
    "taskId": "task_s1",
    "terminalState": "released",
    "workerState": "succeeded"
   },
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_s2",
    "dispatchStatus": "completed",
    "projection": {
     "attention": {
      "categories": [
       "root_completion"
      ],
      "requiresAction": false
     },
     "dispatchId": "ctx_s2",
     "evidence": {
      "durable": true,
      "lastObservedAt": null,
      "liveStatus": "unavailable"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_s2",
     "liveness": {
      "observedAt": 1792605000000,
      "source": "resource_release",
      "verdict": "exited"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "succeeded",
     "parent": null,
     "provider": null,
     "resource": {
      "state": "released"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "unknown",
      "detail": "settled",
      "dispatch": "completed",
      "worker": "succeeded"
     },
     "taskId": "task_s2",
     "workspace": {
      "id": "repo-959::/redacted/main",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "released"
    },
    "runId": "run_redacted",
    "taskId": "task_s2",
    "terminalState": "released",
    "workerState": "succeeded"
   },
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_r1",
    "dispatchStatus": "dispatched",
    "projection": {
     "attention": {
      "categories": [],
      "requiresAction": true
     },
     "dispatchId": "ctx_r1",
     "evidence": {
      "durable": true,
      "lastObservedAt": 1792610612189,
      "liveStatus": "fresh"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_r1",
     "liveness": {
      "observedAt": 1792610612189,
      "source": "agent_status",
      "verdict": "live"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "in_progress",
     "parent": null,
     "provider": {
      "id": "claude",
      "model": null
     },
     "resource": {
      "state": "owned"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "working",
      "detail": "input_accepted",
      "dispatch": "dispatched",
      "worker": "ready"
     },
     "taskId": "task_r1",
     "workspace": {
      "id": "repo-892::/redacted/requests",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "owned"
    },
    "runId": "run_redacted",
    "taskId": "task_r1",
    "terminalState": "active",
    "workerState": "ready"
   }
  ]
 }
}
"""#
    static let workersPage2 = #"""
{
 "id": "fixture",
 "ok": true,
 "result": {
  "counts": {
   "active": 2
  },
  "page": {
   "hasMore": false,
   "limit": 6,
   "nextCursor": null,
   "total": 8
  },
  "scope": {
   "source": "all"
  },
  "warnings": [],
  "workers": [
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_s3",
    "dispatchStatus": "completed",
    "projection": {
     "attention": {
      "categories": [
       "root_completion"
      ],
      "requiresAction": false
     },
     "dispatchId": "ctx_s3",
     "evidence": {
      "durable": true,
      "lastObservedAt": null,
      "liveStatus": "unavailable"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_s3",
     "liveness": {
      "source": "resource_release",
      "verdict": "exited"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "succeeded",
     "parent": null,
     "provider": null,
     "resource": {
      "state": "released"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "unknown",
      "detail": "settled",
      "dispatch": "completed",
      "worker": "succeeded"
     },
     "taskId": "task_s3",
     "workspace": {
      "id": "repo-245::/redacted/main",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "released"
    },
    "runId": "run_redacted",
    "taskId": "task_s3",
    "terminalState": "released",
    "workerState": "succeeded"
   },
   {
    "agentTerminalHandle": "term_redacted",
    "dispatchId": "ctx_s4",
    "dispatchStatus": "completed",
    "projection": {
     "attention": {
      "categories": [
       "root_completion"
      ],
      "requiresAction": false
     },
     "dispatchId": "ctx_s4",
     "evidence": {
      "durable": true,
      "lastObservedAt": null,
      "liveStatus": "unavailable"
     },
     "host": {
      "id": "local",
      "kind": "local"
     },
     "id": "ctx_s4",
     "liveness": {
      "source": "resource_release",
      "verdict": "exited"
     },
     "nextAction": {
      "argv": [],
      "kind": "none"
     },
     "outcome": "succeeded",
     "parent": null,
     "provider": null,
     "resource": {
      "state": "released"
     },
     "role": "worker",
     "runId": "run_redacted",
     "stage": {
      "activity": "unknown",
      "detail": "settled",
      "dispatch": "completed",
      "worker": "succeeded"
     },
     "taskId": "task_s4",
     "workspace": {
      "id": "repo-9::/redacted/remote-box",
      "kind": "folder_or_worktree"
     }
    },
    "resource": {
     "id": "wtr_redacted",
     "ownershipState": "released"
    },
    "runId": "run_redacted",
    "taskId": "task_s4",
    "terminalState": "released",
    "workerState": "succeeded"
   }
  ]
 }
}
"""#
    static let status = #"""
{
 "_meta": {
  "runtimeId": "003f5ab9-9915-4a3b-b9de-e4e1b31c0f75"
 },
 "id": "fixture",
 "ok": true,
 "result": {
  "app": {
   "running": true
  },
  "graph": {
   "state": "ready"
  },
  "runtime": {
   "appVersion": "1.4.233",
   "connectionState": "connected",
   "reachable": true,
   "remoteUpdateSupport": {
    "automatic": true,
    "installMode": "interactive",
    "reason": "available"
   },
   "runtimeId": "runtime-redacted",
   "state": "ready"
  },
  "target": {
   "kind": "local"
  }
 }
}
"""#
}
