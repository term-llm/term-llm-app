async (page) => {
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const results = [];
  const boxes = {};
  async function go(root, view) {
    const direct = root.locator(`.app-header [data-action="view:${view}"]`).first();
    if (await direct.count()) await direct.click();
    else {
      await root.locator('[data-action="viewmenu"]').click();
      await root.locator(`.sheet [data-action="view:${view}"]`).click();
    }
  }
  async function utility(root, action) {
    const direct = root.locator(`.app-header [data-action="${action}"]`).first();
    if (await direct.count()) await direct.click();
    else {
      await root.locator('[data-action="more"]').click();
      if (action === 'settings') assert(await root.locator('[data-action="settings"]').count() === 1, 'Exactly one overflow Settings entry');
      await root.locator(`.sheet [data-action="${action}"]`).click();
    }
  }
  for (let id = 1; id <= 6; id++) {
    const root = page.locator(`[data-phone="${id}"]`);
    boxes[id] = await root.locator('.app-header').boundingBox();
    await root.locator('.app-header').screenshot({path:`output/playwright/header-concepts/header-0${id}-nodes.png`});
    await go(root, 'Attention');
    assert(await root.locator('.main').getByText('Approve the deployment?', {exact: true}).isVisible(), `Concept ${id}: attention navigation`);
    await go(root, 'Sessions');
    assert(await root.locator('.main').getByRole('heading', {name:'Recent sessions'}).isVisible(), `Concept ${id}: session navigation`);
    await go(root, 'Nodes');
    await root.locator('[data-action="all"]').click();
    assert(await root.locator('.node.offline').count() === 2, `Concept ${id}: show offline nodes`);
    await root.locator('[data-action="all"]').click();
    await root.locator('.node').first().click();
    const draft = `Preserved draft for header ${id}`;
    await root.getByRole('textbox', {name:'Draft message'}).fill(draft);
    await go(root, 'Nodes');
    await go(root, 'Chat');
    assert(await root.getByRole('textbox', {name:'Draft message'}).inputValue() === draft, `Concept ${id}: retained draft`);
    const chatBox = await root.locator('.app-header').boundingBox();
    assert(Math.abs(chatBox.height - boxes[id].height) < 1, `Concept ${id}: stable header height across Hub/Chat`);
    await utility(root, 'settings');
    assert(await root.getByRole('dialog', {name:'App settings'}).isVisible(), `Concept ${id}: settings destination`);
    assert(await root.locator('[data-action="settings"]').count() <= 1, `Concept ${id}: no duplicate Settings entry`);
    await root.getByRole('switch').click();
    assert(await root.getByRole('switch').getAttribute('aria-checked') === 'false', `Concept ${id}: mock preference feedback`);
    await root.locator('.sheet [data-action="close"]').click();
    await utility(root, 'connections');
    assert(await root.getByRole('dialog', {name:'Connections'}).isVisible(), `Concept ${id}: connections destination`);
    await root.locator('.sheet [data-action="features:Work Hub"]').click();
    assert(await root.getByRole('dialog', {name:'Work Hub'}).isVisible(), `Concept ${id}: scoped connection actions`);
    await root.locator('.sheet [data-action="close"]').click();
    assert(await root.getByRole('textbox', {name:'Draft message'}).inputValue() === draft, `Concept ${id}: admin does not replace conversation`);
    results.push({concept:id, status:'passed', checks:['views', 'offline filter', 'draft retention', 'stable height', 'one settings entry', 'scoped connections']});
  }
  await page.getByRole('button', {name:'Simulate sync', exact:true}).click();
  for (let id = 1; id <= 6; id++) {
    const root = page.locator(`[data-phone="${id}"]`);
    const box = await root.locator('.app-header').boundingBox();
    assert(Math.abs(box.height - boxes[id].height) < 1, `Concept ${id}: no header jump during sync`);
    assert(await root.locator('.sync-label').first().textContent() === 'Syncing…', `Concept ${id}: visible sync feedback`);
  }
  await page.screenshot({path:'output/playwright/header-concepts/six-headers-syncing.png', fullPage:true});
  await page.waitForFunction(() => Object.values(window.headerPrototype.state).every(s => !s.sync));
  await page.screenshot({path:'output/playwright/header-concepts/six-headers-chat.png', fullPage:true});
  for (let id = 1; id <= 6; id++) {
    await page.locator(`[data-phone="${id}"] .app-header`).screenshot({path:`output/playwright/header-concepts/header-0${id}-chat.png`});
  }
  await page.getByRole('button', {name:'Reset concepts', exact:true}).click();
  await page.screenshot({path:'output/playwright/header-concepts/six-headers.png', fullPage:true});
  for (let id = 1; id <= 6; id++) {
    const name = ['command-rail','workspace-segments','context-switcher','breadcrumb-bar','floating-dock','session-rail'][id-1];
    await page.locator(`[data-concept="${id}"]`).screenshot({path:`output/playwright/header-concepts/0${id}-${name}.png`});
  }
  return {result:'PASS', concepts:results, sync:'fixed geometry and visible feedback on all six'};
}
