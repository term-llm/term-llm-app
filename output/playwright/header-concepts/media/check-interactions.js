async (page) => {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const model = id => page.evaluate(id => JSON.parse(JSON.stringify(window.mediaHeaderPrototype.state[id])), id);
  const roots = id => page.locator(`[data-phone="${id}"]`);
  async function go(root, id, view) {
    let direct = root.locator(`.app-header [data-action="view:${view}"], .bottom-nav [data-action="view:${view}"]`).first();
    if (await direct.count()) { await direct.click(); return; }
    if (id === 2) {
      await root.locator(`[data-action="group:${['Nodes','Chat'].includes(view)?'Work':'Listen'}"]`).click();
      await root.locator(`.app-header [data-action="view:${view}"]`).first().click();
    } else {
      await root.locator(`[data-action="${id===4?'drawer':'destinations'}"]`).click();
      await root.locator(`.sheet [data-action="view:${view}"]`).click();
    }
  }
  async function settings(root, id) {
    const direct = root.locator('.app-header [data-action="settings"]');
    if (await direct.count()) await direct.click();
    else {
      await root.locator(`[data-action="${id===4?'drawer':'more'}"]`).click();
      assert(await root.locator('.sheet [data-action="settings"]').count()===1, `Concept ${id}: one Settings path`);
      await root.locator('.sheet [data-action="settings"]').click();
    }
  }
  const heights = {}, results = [];
  for (let id=1;id<=6;id++) {
    const root=roots(id);
    heights[id]=(await root.locator('.app-header').boundingBox()).height;
    const original=(await model(id)).media;
    await go(root,id,'Chat');
    await root.getByRole('textbox',{name:'Draft message'}).fill(`Keep draft ${id} while listening`);
    await go(root,id,'Music');
    assert(await root.locator('.main').getByRole('heading',{name:'Music',exact:true}).isVisible(),`Concept ${id}: Music is a destination`);
    let s=await model(id);
    assert(s.media.kind==='podcast'&&s.media.playing&&s.media.position===original.position,`Concept ${id}: browsing Music preserves the podcast`);
    assert(Math.abs((await root.locator('.app-header').boundingBox()).height-heights[id])<1,`Concept ${id}: navigation does not change header height`);
    await root.locator('.player-strip [data-action="toggle"]').click();
    assert(!(await model(id)).media.playing,`Concept ${id}: persistent Pause works outside Podcasts`);
    await root.locator('.player-strip [data-action="toggle"]').click();
    await root.locator('.main [data-action="start:music"]').first().click();
    assert(await root.getByRole('dialog',{name:'Switch playback?'}).isVisible(),`Concept ${id}: explicit audio handoff`);
    assert((await model(id)).media.kind==='podcast',`Concept ${id}: no premature playback takeover`);
    await root.locator('.sheet .close').click();
    assert((await model(id)).media.kind==='podcast'&&(await model(id)).media.playing,`Concept ${id}: cancel keeps audio playing`);
    await root.locator('.main [data-action="start:music"]').first().click();
    await root.locator('.sheet [data-action="confirm-play"]').click();
    assert((await model(id)).media.kind==='music'&&(await model(id)).media.playing,`Concept ${id}: one music playback owner`);
    assert(await root.locator('.player-strip [data-action="next"]').count()===1,`Concept ${id}: music uses track controls`);
    assert(await root.locator('.player-strip [data-action="forward30"]').count()===0,`Concept ${id}: no podcast skip controls on music`);
    await go(root,id,'Podcasts');
    assert(await root.locator('.main').getByRole('heading',{name:'Podcasts',exact:true}).isVisible(),`Concept ${id}: Podcasts is a destination`);
    assert((await model(id)).media.kind==='music',`Concept ${id}: browsing Podcasts preserves music`);
    await root.locator('.player-strip [data-action="player"]').first().click();
    assert(await root.getByRole('dialog',{name:'Now playing'}).isVisible(),`Concept ${id}: expand player from any destination`);
    assert(await root.locator('.sheet [data-action="speed"]').count()===0,`Concept ${id}: music has no podcast speed control`);
    await root.locator('.sheet .close').click();
    await root.locator('.main [data-action="start:podcast"]').click();
    await root.locator('.sheet [data-action="confirm-play"]').click();
    assert((await model(id)).media.position===original.position,`Concept ${id}: podcast resumes its saved position`);
    await root.locator('.player-strip [data-action="player"]').first().click();
    await root.locator('.sheet [data-action="back15"]').click();
    await root.locator('.sheet [data-action="forward30"]').click();
    assert((await model(id)).media.position===original.position+15,`Concept ${id}: source-specific seek controls`);
    await root.locator('.sheet [data-action="speed"]').click();
    assert((await model(id)).media.speed===1.5,`Concept ${id}: podcast speed control`);
    await root.locator('.sheet [data-action="queue"]').click();
    assert(await root.getByRole('dialog',{name:'Up Next'}).isVisible(),`Concept ${id}: accessible podcast queue`);
    await root.locator('.sheet .close').click();
    await go(root,id,'Chat');
    assert(await root.getByRole('textbox',{name:'Draft message'}).inputValue()===`Keep draft ${id} while listening`,`Concept ${id}: independent retained chat`);
    await settings(root,id);
    assert(await root.getByRole('dialog',{name:'App settings'}).isVisible(),`Concept ${id}: app Settings separate from media`);
    await root.locator('.sheet .close').click();
    results.push({concept:id,result:'PASS',checks:['all four destinations','browse without stopping audio','persistent pause','confirmed playback handoff','music track controls','podcast seek/speed/queue','saved listening position','retained chat draft','one app Settings path']});
  }
  await page.getByRole('button',{name:'Sync',exact:true}).click();
  for(let id=1;id<=6;id++)assert(Math.abs((await roots(id).locator('.app-header').boundingBox()).height-heights[id])<1,`Concept ${id}: fixed geometry while syncing`);
  await page.waitForFunction(()=>Object.values(window.mediaHeaderPrototype.state).every(s=>!s.sync));
  // Visualize the important distinction: library destination is independent of the playback source.
  for(let id=1;id<=6;id++)await go(roots(id),id,'Music');
  await page.screenshot({path:'output/playwright/header-concepts/media/browsing-music-podcast-playing.png',fullPage:true});
  await roots(5).screenshot({path:'output/playwright/header-concepts/media/flow-03-music-podcast.png'});
  for(let id=1;id<=6;id++)await go(roots(id),id,'Nodes');
  await roots(5).screenshot({path:'output/playwright/header-concepts/media/flow-02-nodes-podcast.png'});
  await page.getByRole('button',{name:'Idle',exact:true}).click();
  for(let id=1;id<=6;id++)assert(Math.abs((await roots(id).locator('.app-header').boundingBox()).height-heights[id])<1,`Concept ${id}: stable header while playback is idle`);
  await page.screenshot({path:'output/playwright/header-concepts/media/six-media-headers-idle.png',fullPage:true});
  await roots(5).screenshot({path:'output/playwright/header-concepts/media/flow-01-idle.png'});
  await page.getByRole('button',{name:'Music playing',exact:true}).click();
  for(let id=1;id<=6;id++)await go(roots(id),id,'Podcasts');
  await page.screenshot({path:'output/playwright/header-concepts/media/browsing-podcasts-music-playing.png',fullPage:true});
  await roots(5).screenshot({path:'output/playwright/header-concepts/media/flow-04-podcasts-music.png'});
  await page.getByRole('button',{name:'Podcast playing',exact:true}).click();
  for(let id=1;id<=6;id++)await go(roots(id),id,'Nodes');
  await page.screenshot({path:'output/playwright/header-concepts/media/six-media-headers.png',fullPage:true});
  for(let id=1;id<=6;id++)await page.locator(`[data-concept="${id}"]`).screenshot({path:`output/playwright/header-concepts/media/concept-0${id}.png`});
  return {result:'PASS',concepts:results,geometry:'Stable across destinations, idle/playing, and sync',note:'Prototype state only; no real audio sessions are started'};
}
