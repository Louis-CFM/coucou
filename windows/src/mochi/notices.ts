// Local event policy. No model, transcript, network or animation timer.
import type { AgentTask, ApprovalInfo } from "../core/state";
export interface PetNotice { key: string; pet: string; text: string; urgent: boolean; view?: string }
export class PetNotices {
  private seen = new Set<string>();
  private previous = new Map<string,string>();
  observe(tasks: readonly AgentTask[], pending: ApprovalInfo | null): PetNotice[] {
    const notices: PetNotice[] = [];
    const ids = new Set(tasks.map(t=>t.id));
    for (const id of this.previous.keys()) if (!ids.has(id)) this.previous.delete(id);
    for (const task of tasks) {
      const before = this.previous.get(task.id);
      const state = pending?.pillId === task.id ? (pending.questions ? "question" : "approval") : task.state;
      this.previous.set(task.id,state);
      const urgent = ["approval","question","error","ratelimit"].includes(state);
      if (!urgent && !(state === "finished" && before && before !== state)) continue;
      const key = `${task.id}:${state}:${pending?.pillId===task.id ? pending.requestId : `${task.sessionId??""}:${task.stepSeq??task.stepIndex}`}`;
      if (this.seen.has(key)) continue;
      this.seen.add(key);
      if(this.seen.size>128) this.seen.delete(this.seen.values().next().value!);
      const text = state === "approval" ? "I need your permission to continue." : state === "question" ? "I have a question for you." :
        state === "error" ? "Something went wrong. Review the session." : state === "ratelimit" ? "This session is waiting for its usage limit." : "The session has finished. Review the result.";
      notices.push({key,pet:task.id,text,urgent,view:state === "approval" || state === "question" ? state : "overview"});
    }
    return notices;
  }
}
/** Bounded queue; permission requests win, and no event repeats after dismissal. */
export class NoticeQueue {
  private items: PetNotice[] = [];
  private seen = new Set<string>();
  push(notice: PetNotice) {
    if(this.seen.has(notice.key)) return;
    this.seen.add(notice.key);
    if(this.seen.size>128)this.seen.delete(this.seen.values().next().value!);
    this.items=this.items.filter(n=>n.pet!==notice.pet || n.urgent);
    this.items.push(notice);
    this.items.sort((a,b)=>Number(b.urgent)-Number(a.urgent));
    this.items=this.items.slice(0,16);
  }
  take(): PetNotice | undefined { return this.items.shift(); }
  get size() { return this.items.length; }
}
