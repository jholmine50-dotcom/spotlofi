
/* ================= MINE FORK: comportamento da pele ================= */
(function(){
  document.body.classList.add('mc');
  // frase amarela ao lado do logo da barra de título
  const SPLASH=['Mine fork!','Agora no Minecraft!','Letra no mundo!','Feito em blocos!','Bora de show!','Também tem holofote!'];
  function splash(){
    if(document.querySelector('.mc-splash'))return;
    const host=document.querySelector('.titlebar'); if(!host)return;
    // acha o "ListenUp" da barra (o menor elemento com esse texto)
    let logo=null;
    host.querySelectorAll('*').forEach(e=>{const t=(e.textContent||'').trim();const r=e.getBoundingClientRect();
      if(/^ListenUp$/.test(t)&&r.width>0&&(!logo||r.width<=logo.getBoundingClientRect().width))logo=e});
    const s=document.createElement('div'); s.className='mc-splash';
    s.textContent=SPLASH[Math.floor(Math.random()*SPLASH.length)];
    if(getComputedStyle(host).position==='static')host.style.position='relative';
    const hr=host.getBoundingClientRect(), r=logo?(logo.closest('button,a,div')||logo).getBoundingClientRect():null;
    s.style.left=((r?r.right-hr.left:200)+6)+'px'; s.style.top=((r?r.bottom-hr.top:40)-4)+'px';
    host.appendChild(s);
  }
  setTimeout(splash,600); addEventListener('resize',()=>{const o=document.querySelector('.mc-splash');if(o){o.remove();splash()}});
  // clique de botão: som curtinho gerado na hora (nada copiado do jogo)
  let ac=null;
  function click(){
    try{
      ac=ac||new (window.AudioContext||window.webkitAudioContext)();
      const t=ac.currentTime,o=ac.createOscillator(),g=ac.createGain(),f=ac.createBiquadFilter();
      o.type='square';o.frequency.setValueAtTime(820,t);o.frequency.exponentialRampToValueAtTime(380,t+.05);
      f.type='lowpass';f.frequency.value=2600;
      g.gain.setValueAtTime(.0001,t);g.gain.exponentialRampToValueAtTime(.09,t+.004);g.gain.exponentialRampToValueAtTime(.0001,t+.07);
      o.connect(f);f.connect(g);g.connect(ac.destination);o.start(t);o.stop(t+.08);
    }catch(e){}
  }
  document.addEventListener('pointerdown',e=>{
    if(localStorage.getItem('mcClick')==='0')return;
    if(e.target.closest('button,.sb-item,.chip,.dk,[data-a]'))click();
  },true);
})();
