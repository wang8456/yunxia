/* 应用内输入框 / 确认框。
   为什么不用 window.prompt：iOS 独立模式、微信内置浏览器、部分安卓 WebView 直接
   把 prompt 屏蔽掉——返回 null，用户点「新建」就真的什么都没发生，而且没有任何提示。
   这里用 DOM 画一个跟主题一致的弹层，返回 Promise。 */

type AskOpts = {
  title: string
  value?: string
  placeholder?: string
  okText?: string
  danger?: boolean
  /** 只有确认，没有输入框 */
  confirmOnly?: boolean
  body?: string
}

let styled = false
function injectStyle() {
  if (styled) return
  styled = true
  const css = `
.ak-mask{position:fixed;inset:0;z-index:9000;display:flex;align-items:flex-end;justify-content:center;
  background:rgba(16,24,40,.32);backdrop-filter:blur(2px);animation:akf .16s ease}
@media(min-width:520px){.ak-mask{align-items:center}}
.ak-card{width:100%;max-width:420px;background:var(--surface,#fff);border-radius:18px 18px 0 0;
  padding:18px 18px calc(16px + env(safe-area-inset-bottom));box-sizing:border-box;
  box-shadow:0 -8px 40px rgba(16,24,40,.18);animation:aku .2s cubic-bezier(.2,.9,.3,1)}
@media(min-width:520px){.ak-card{border-radius:16px;padding-bottom:16px}}
.ak-title{font-size:15px;font-weight:600;color:var(--ink,#1d1d1f);margin-bottom:12px}
.ak-body{font-size:13px;line-height:1.6;color:var(--ink3,#8e8e93);margin:-4px 0 14px;white-space:pre-wrap}
.ak-in{width:100%;box-sizing:border-box;height:44px;padding:0 12px;border-radius:11px;
  border:1px solid var(--line,#dfe4ea);background:var(--bg2,#f7f8fa);color:var(--ink,#1d1d1f);
  font-size:15px;outline:none}
.ak-in:focus{border-color:var(--ac,#1677f8);background:var(--surface,#fff)}
.ak-row{display:flex;gap:10px;margin-top:16px}
.ak-btn{flex:1;height:44px;border-radius:11px;border:1px solid var(--line,#dfe4ea);
  background:var(--surface,#fff);color:var(--ink,#1d1d1f);font-size:15px;cursor:pointer}
.ak-btn.ok{background:var(--ac,#1677f8);border-color:transparent;color:#fff;font-weight:600}
.ak-btn.ok.danger{background:#e45e53}
.ak-btn:active{opacity:.75}
@keyframes akf{from{opacity:0}to{opacity:1}}
@keyframes aku{from{transform:translateY(18px)}to{transform:translateY(0)}}
`
  const el = document.createElement('style')
  el.textContent = css
  document.head.appendChild(el)
}

export function ask(opts: AskOpts): Promise<string | null> {
  injectStyle()
  return new Promise((resolve) => {
    const mask = document.createElement('div')
    mask.className = 'ak-mask'
    const card = document.createElement('div')
    card.className = 'ak-card'
    const title = document.createElement('div')
    title.className = 'ak-title'
    title.textContent = opts.title
    card.appendChild(title)

    if (opts.body) {
      const b = document.createElement('div')
      b.className = 'ak-body'
      b.textContent = opts.body
      card.appendChild(b)
    }

    let input: HTMLInputElement | null = null
    if (!opts.confirmOnly) {
      input = document.createElement('input')
      input.className = 'ak-in'
      input.value = opts.value || ''
      input.placeholder = opts.placeholder || ''
      input.spellcheck = false
      card.appendChild(input)
    }

    const row = document.createElement('div')
    row.className = 'ak-row'
    const cancel = document.createElement('button')
    cancel.className = 'ak-btn'
    cancel.type = 'button'
    cancel.textContent = '取消'
    const ok = document.createElement('button')
    ok.className = 'ak-btn ok' + (opts.danger ? ' danger' : '')
    ok.type = 'button'
    ok.textContent = opts.okText || '确定'
    row.append(cancel, ok)
    card.appendChild(row)
    mask.appendChild(card)
    document.body.appendChild(mask)

    const close = (v: string | null) => {
      document.removeEventListener('keydown', onKey)
      mask.remove()
      resolve(v)
    }
    const submit = () => {
      if (!input) return close('')
      const v = input.value.trim()
      if (!v) {
        input.focus()
        return
      }
      close(v)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close(null)
      if (e.key === 'Enter') {
        e.preventDefault()
        submit()
      }
    }
    cancel.onclick = () => close(null)
    ok.onclick = submit
    mask.addEventListener('click', (e) => {
      if (e.target === mask) close(null)
    })
    document.addEventListener('keydown', onKey)
    setTimeout(() => {
      if (input) {
        input.focus()
        input.select()
      } else ok.focus()
    }, 60)
  })
}

export async function confirmBox(title: string, body = '', okText = '确定', danger = true) {
  const r = await ask({ title, body, okText, danger, confirmOnly: true })
  return r !== null
}
