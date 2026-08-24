const menuButton = document.querySelector('.menu-toggle');
const navigation = document.querySelector('#primary-nav');

menuButton?.addEventListener('click', () => {
  const isOpen = menuButton.getAttribute('aria-expanded') === 'true';
  menuButton.setAttribute('aria-expanded', String(!isOpen));
  navigation.dataset.open = String(!isOpen);
});

navigation?.addEventListener('click', (event) => {
  if (event.target.matches('a')) {
    menuButton?.setAttribute('aria-expanded', 'false');
    navigation.dataset.open = 'false';
  }
});

const tabs = [...document.querySelectorAll('[role="tab"]')];
const trajectoryImage = document.querySelector('#trajectory-image');
const trajectoryCaption = document.querySelector('#trajectory-caption');

function activateTab(tab) {
  tabs.forEach((item) => {
    const isActive = item === tab;
    item.setAttribute('aria-selected', String(isActive));
    item.tabIndex = isActive ? 0 : -1;
  });
  trajectoryImage.src = tab.dataset.image;
  trajectoryImage.alt = tab.dataset.alt;
  trajectoryCaption.textContent = tab.dataset.caption;
  document.querySelector('#trajectory-panel').setAttribute('aria-labelledby', tab.id);
}

tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => activateTab(tab));
  tab.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    let next = index;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    tabs[next].focus();
    activateTab(tabs[next]);
  });
});

document.querySelectorAll('audio').forEach((player) => {
  player.addEventListener('play', () => {
    document.querySelectorAll('audio').forEach((other) => {
      if (other !== player) other.pause();
    });
  });
});

document.querySelector('#year').textContent = new Date().getFullYear();
