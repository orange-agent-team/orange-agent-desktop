#!/usr/bin/env python3
"""Check the M0 privacy and budget design artifacts, sample arithmetic and pinned observed receipts."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
DOC=ROOT/'docs/privacy-budget'
SECTIONS={'data':'01-data-decisions.md','quote':'02-quote-confirmation.md','fallback':'03-resource-fallback.md','review':'04-scenario-review.md'}
MARKERS={
    'data':['桌面本地会话','Web 发送原文询价','Web 发送规则遮盖文本询价','可以读取明文','明文','音频上传预检','SHA-256','残余线索'],
    'quote':['模型版本','节点','最高费用','owner_id','root_budget_id','已预留','余额不足','预算不足','有效期','2,200'],
    'fallback':['LocalOnly','下载模型或导入已有文件','换模型','允许远程处理','退出或稍后处理','提交远程 Job','独立批准上传','桌面内直接远程下单'],
    'review':['联系人邮箱','明文','6,800','3,800','5,200','5,400','2,200','撤回成员资格','原报价','真实试点']
}
def load(path):return json.loads(path.read_bytes())
def require(ok,reason):
    if not ok:raise ValueError(reason)
def money(value):
    require(isinstance(value,str) and value.isascii() and value.isdigit() and str(int(value))==value,'Expected canonical unsigned microcredits')
    return int(value)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--section',choices=SECTIONS,required=True);parser.add_argument('--evidence-root',type=Path,required=True)
    args=parser.parse_args();base=args.evidence_root.resolve();section=args.section;doc=(DOC/SECTIONS[section]).read_text()
    for marker in MARKERS[section]:require(marker in doc,'Missing product decision: '+marker)
    case=load(DOC/'review-cases.json');require(case['requirement']=='PRD-004' and case['money_unit']=='microcredit','Wrong requirement or amount unit')
    if section in ('data','review'):
        sample=case['text_case'];source=sample['input'];rules=sorted(set(sample['rules']),key=len,reverse=True)
        output=[];offset=0
        while offset<len(source):
            match=next((rule for rule in rules if rule and source.startswith(rule,offset)),None)
            if match:
                output.append('[已遮盖]');offset+=len(match)
            else:
                output.append(source[offset]);offset+=1
        text=''.join(output)
        require(text==sample['reviewed_text'] and sample['remaining_context'] in text and money(sample['upload_maximum'])==0,'Incorrect outgoing text or prequote cost')
    if section in ('quote','review'):
        audio=case['audio_example'];require((money(audio['duration_ms'])*money(audio['price_per_minute'])+59999)//60000==money(audio['maximum']),'Invalid ASR cap')
        b=case['budget_example'];available=money(b['limit'])-money(b['spent'])-money(b['other_holds'])
        require((available,available-money(b['next_maximum']),money(b['spent'])+money(b['next_maximum']),available-money(b['next_actual']))==tuple(money(b[k]) for k in ('available_before','available_after_maximum','two_steps_maximum','available_after_settlement')),'Incorrect root budget projection')
        require(b['owner_kind']=='team' and b['root']=='same-root' and b['member_may_view_full_wallet'] is False,'Unexpected payer or wallet disclosure')
    if section=='fallback':
        states=case['resource_states']
        require({r['selected'] for r in states}=={'download_or_import','change_local_profile','review_remote','exit'} and all(r['send_workspace'] is False and r['submit_job'] is False for r in states),'A fallback action escalated local data authority')
    evidence=load(DOC/'verified-sources.json')
    for item in evidence[section]:
        path=(base/item['file']).resolve()
        require(path.is_relative_to(base) and path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==item['sha256'],'Unverifiable source receipt: '+item['file'])
        content=path.read_text()
        for marker in item['assertions']:require(marker in content,'Observed behavior missing from '+item['file']+': '+marker)
    print('PASS original PRD-004 '+section+': '+SECTIONS[section]+', independently evaluated examples and '+str(len(evidence[section]))+' source-bound receipts. M0 product review; human usability and hardware qualification tracked separately.')

if __name__=='__main__':main()
