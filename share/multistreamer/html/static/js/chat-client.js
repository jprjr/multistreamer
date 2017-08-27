/* var icons created by chat.lua */
var chatWrapper = document.getElementById('chatwrapper');
var chatMessages = document.getElementById('chatmessages');
var chatViewers = document.getElementById('chatviewers');
var chatInput = undefined;
var chatPickerList = undefined;
var accountList = undefined;
var commonmark = window.commonmark;
var parser = new commonmark.Parser();
var writer = new commonmark.HtmlRenderer();
var domParser = new DOMParser();
var curInput;
var curAccount;
var tarAccount;
var ws;
var live = false;
var connected = false;
var reconnect_func;
var seconds = 0;
var scroller = zenscroll.createScroller(chatMessages);
var transitionEvent = whichTransitionEvent();

var isCompact = findGetParameter('compact');
var isWidget = findGetParameter('widget');
var fadeoutTime = findGetParameter('fadeout');
var shouldHideIRC = findGetParameter('hide_irc');
var shouldHideWhispers = findGetParameter('hide_pm');
var messageFromBottom = findGetParameter('from_bottom');
var showProfilePictures = findGetParameter('show_picture');

if(messageFromBottom !== null) {
  chatMessages.style['justify-content'] = 'flex-end';
}


if(fadeoutTime === true || fadeoutTime === 0) {
    fadeoutTime = 10;
}
if(fadeoutTime !== null) {
    fadeoutTime *= 1000;
}

icons['irc'] =
    '<svg class="chaticon irc" xmlns="http://www.w3.org/2000/svg" viewBox="0 ' +
    '0 20 20"><path d="m 18.477051,7.5280762 h -4.390137 l -1.212891,4.957030' +
    '8 h 4.060547 v 1.779786 h -4.521972 l -1.371094,5.550293 H 9.3408203 L 1' +
    '0.711914,14.264893 H 7.1523437 L 5.78125,19.815186 H 4.0805664 L 5.45166' +
    '02,14.264893 H 1.5229492 V 12.485107 H 5.9130859 L 7.1259766,7.5280762 H' +
    ' 3.0654297 V 5.748291 H 7.5874023 L 8.9716797,0.18481445 H 10.672363 L 9' +
    '.2880859,5.748291 h 3.5595701 l 1.384278,-5.56347655 h 1.700683 L 14.548' +
    '34,5.748291 h 3.928711 z M 12.425781,7.501709 H 8.8134766 l -1.2392579,5' +
    '.009766 h 3.6123043 z" /></svg>';

function whichTransitionEvent(){
    var t;
    var el = document.createElement('fakeelement');
    var transitions = {
      'transition':'transitionend',
      'OTransition':'oTransitionEnd',
      'MozTransition':'transitionend',
      'WebkitTransition':'webkitTransitionEnd'
    }

    for(t in transitions){
        if( el.style[t] !== undefined ){
            return transitions[t];
        }
    }
}

function findGetParameter(parameterName) {
    var result = null,
        tmp = [];
    location.search
    .substr(1)
        .split("&")
        .forEach(function (item) {
        tmp = item.split("=");
        if (tmp[0] === parameterName) {
            if(tmp.length === 1) {
                result = true;
            }
            else {
               result = tmp[1];
            }
        }
    });
    return result;
}

function atBottom(elem) {
    if(!isWidget) {
        return true;
    }
    return elem.scrollHeight - elem.scrollTop === elem.clientHeight;
}

function buildChatPickerList(accounts) {
    var chatPickerTest = document.getElementById('chatpickerlist');
    if(chatPickerTest !== undefined && chatPickerTest !== null) {
        chatWrapper.removeChild(chatPickerTest);
        chatPickerTest = undefined;
        chatPickerList = undefined;
    }

    chatPickerList = document.createElement('div');
    chatPickerList.id = 'chatpickerlist';
    var pickerMade = false;

    if(accounts !== undefined && accounts !== null) {
        accounts.forEach(function(account) {
            if(icons[account.network.name] && account.writable === true) {
                var chatPicker = document.createElement('div');
                chatPicker.className = 'chatpicker';
                var svgIcon = domParser.parseFromString(icons[account.network.name],'image/svg+xml').documentElement;
                svgIcon.setAttribute('class','chaticon ' + account.network.name);
                var pName = document.createElement('p');
                pName.textContent = account.name;
                chatPicker.appendChild(svgIcon);
                chatPicker.appendChild(pName);
                chatPicker.onclick = function() {
                    buildChatInput(account);
                };
                chatPickerList.appendChild(chatPicker);
                pickerMade = true;
            }
        });
    }

    if(pickerMade === false) {
        var chatPicker = document.createElement('div');
        chatPicker.className = 'chatpicker';
        if(live) {
            chatPicker.innerHTML = '<p>No accounts available</p>'
        }
        else {
            chatPicker.innerHTML = '<p>Stream not started</p>'
        }
        chatPicker.onclick = function() {
            buildChatInput(null);
        };
        chatPickerList.appendChild(chatPicker);
    }

    if(chatInput !== undefined) {
        chatWrapper.removeChild(chatInput);
        chatInput = undefined;
    }
    chatWrapper.appendChild(chatPickerList);
}

function buildChatBox(account, target_account) {
    var inputElement = document.createElement('input');
    var account_id = account.id
    var target_id = target_account.id
    inputElement.onkeypress = function(e) {
        var event = e || window.event;
        var charCode = event.which || event.keyCode;

        if(charCode === 13) {
            var text = inputElement.value;
            var parts = text.split(' ');
            var t = {
                account_id: account_id,
                cur_stream_account_id: target_id,
            };

            if(parts[0] == '/me') {
                parts.splice(0,1);
                text = parts.join(' ');
                t.type = 'emote';
            }
            else {
                t.type = 'text';
            }
            t.text = text;

            ws.send(JSON.stringify(t));
            inputElement.value = '';
        }
    };
    return inputElement;
}


function buildChatInput(account) {
    var chatInputTest = document.getElementById('chatinput');
    if(chatInputTest !== undefined && chatInputTest !== null) {
        chatWrapper.removeChild(chatInputTest);
        chatInputTest = undefined;
        chatInput = undefined;
    }

    chatInput = document.createElement('div');
    chatInput.id = 'chatinput';

    var nameElement = document.createElement('div');
    nameElement.className = 'name';

    var messageElement = document.createElement('div');
    messageElement.className = 'message';
    var inputElement;

    if(account !== null) {
        var svgIcon = domParser.parseFromString(icons[account.network.name],'image/svg+xml').documentElement;
        svgIcon.setAttribute('class','chaticon ' + account.network.name);
        var pName = document.createElement('p');
        pName.textContent = account.name;
        nameElement.appendChild(svgIcon);
        nameElement.appendChild(pName);
        curAccount = account; // the 'from' account
        if(account.ready === true) {
            inputElement = buildChatBox(account, account);
            tarAccount = account;
            curInput = inputElement;
        }
        else {
            var liveAccounts = []
            accountList.forEach(function(a) {
              if(a.live === true && a.network.displayName.localeCompare(account.network.displayName) === 0) {
                  liveAccounts.push(a);
              }
            });
            if(liveAccounts.length == 1) {
                inputElement = buildChatBox(account,liveAccounts[0]);
                inputElement.disabled = true;
                tarAccount = liveAccounts[0];
                curInput = inputElement;
                ws.send(JSON.stringify({
                    type: 'writer',
                    account_id: account.id,
                    cur_stream_account_id: liveAccounts[0].id
                }));
            }
            else {
                inputElement = document.createElement('select');
                curInput = inputElement;
                var firstOpt = document.createElement('option');
                firstOpt.disabled = true;
                firstOpt.selected = true;
                firstOpt.innerHTML = 'Choose which stream to chat on'
                inputElement.appendChild(firstOpt);
                liveAccounts.forEach(function(a) {
                    var optionElement = document.createElement('option');
                    optionElement.innerHTML = a.name;
                    optionElement.value = a.id;
                    optionElement.tarAccount = a;
                    inputElement.appendChild(optionElement);
                });
                inputElement.onchange = function() {
                    inputElement.disabled = true;
                    liveAccounts.forEach(function(a) {
                      if (a.id === parseInt(inputElement.value,10)) {
                        tarAccount = a;
                        var svgIcon = domParser.parseFromString(icons[account.network.name],'image/svg+xml').documentElement;
                        svgIcon.setAttribute('class','chaticon ' + account.network.name);
                        var pName = document.createElement('p');
                        pName.textContent = account.name + ' -> ' + a.name;
                        nameElement.appendChild(svgIcon);
                        nameElement.appendChild(pName);
                      }
                    });
                    ws.send(JSON.stringify({
                        type: 'writer',
                        account_id: account.id,
                        cur_stream_account_id: inputElement.value,
                    }));
                };
            }
        }
        messageElement.appendChild(inputElement);
    }
    else {
        curAccount = undefined;
        curInput = undefined;
        if(live) {
            nameElement.innerHTML = '<p>No account chosen - click to choose</p>';
        }
        else {
            nameElement.innerHTML = '<p>Stream not started</p>';
        }
    }
    chatInput.appendChild(nameElement);
    chatInput.appendChild(messageElement);
    nameElement.firstChild.onclick = function() {
        buildChatPickerList(accountList);
    };
    if(chatPickerList !== undefined) {
        chatWrapper.removeChild(chatPickerList);
        chatPickerList = undefined;
    }
    if(chatWrapper !== null) {
        chatWrapper.appendChild(chatInput);
    }
    if(curInput !== undefined) {
        curInput.focus();
    }
}

function appendMessage(msg) {
  if(msg.network === 'irc' && shouldHideIRC) {
      return;
  }
  if(msg.to !== undefined && shouldHideWhispers) {
      return;
  }
  var newMsg = document.createElement('div');
  var nameDiv = document.createElement('div');
  var nameImgDiv = document.createElement('div');
  var msgDiv = document.createElement('div');
  var svgIcon = domParser.parseFromString(icons[msg.network],'image/svg+xml');
  var t;
  var nameMarkdown;
  var msgMarkdown;

  /* <div class="chatmessage (private)">
   *   <div class="name">
   *     <div class="icon">
   *       <img src="">
   *       <svg>
   *     </div>
   *     <p>Name</p>
   *   </div>
   *   <div class="text/emote">
   *     <p>Message</p>
   *   </div>
   * </div>
  */

  newMsg.setAttribute('class','chatmessage');
  nameDiv.setAttribute('class','name');
  nameImgDiv.setAttribute('class','icon');
  msgDiv.setAttribute('class','text');

  if(isCompact) {
    newMsg.setAttribute('class',newMsg.getAttribute('class') + ' compact');
  }

  if(msg.to) {
    newMsg.setAttribute('class',newMsg.getAttribute('class') + ' private');
    msg.from.name = msg.from.name + ' -> ' + msg.to.name
  }

  if(showProfilePictures && msg.from.picture) {
    var profileImg = document.createElement('img');
    profileImg.setAttribute('class','chaticon');
    profileImg.setAttribute('src',msg.from.picture);
    svgIcon.documentElement.setAttribute('class','minicon ' + msg.network);
    nameImgDiv.appendChild(profileImg);
  }
  else {
    svgIcon.documentElement.setAttribute('class','chaticon ' + msg.network);
  }
  nameImgDiv.appendChild(svgIcon.documentElement);

  if(msg.type === 'emote') {
      nameDiv.setAttribute('class','emote');
      if(msg.markdown !== undefined && msg.markdown !== null) {
        msg.from.name = msg.from.name + ' ' + msg.markdown;
        delete msg.markdown
      }
      else {
        msg.from.name = msg.from.name + ' ' + msg.text;
      }
      delete msg.text;
  }

  nameMarkdown = parser.parse(msg.from.name)
  nameDiv.innerHTML = writer.render(nameMarkdown);

  if(msg.markdown !== undefined && msg.markdown !== null) {
    msg.text = msg.markdown;
  }

  if(msg.text !== undefined && msg.text !== null) {
    msgMarkdown = parser.parse(msg.text);
    msgDiv.innerHTML = writer.render(msgMarkdown);
    msg.text = true;
  }
  else {
    msg.text = false;
  }


  nameDiv.insertBefore(nameImgDiv,nameDiv.firstChild);
  newMsg.appendChild(nameDiv);

  if(msg.text) {
    newMsg.appendChild(msgDiv);
  }


  if(fadeoutTime) {
      newMsg.style.opacity = 1;
      newMsg.style.transition = 'opacity 1s';
      setTimeout(function() {
          newMsg.style.opacity = 0;
      }, fadeoutTime);
      newMsg.addEventListener(transitionEvent, function() {
          chatMessages.removeChild(newMsg);
      });
  }


  var shouldScroll = atBottom(chatMessages);

  chatMessages.appendChild(newMsg);
  if(shouldScroll) {
    scroller.toY(chatMessages.scrollHeight);
  }
}

function updateAccountList(accounts) {
    accountList = [];
    Object.keys(accounts).forEach(function(id) {
        accounts[id].id = parseInt(id,10);
        accounts[id].viewer_count = null;
        accountList.push(accounts[id]);
    });
    accountList.sort(function(a,b) {
        var netSort = a.network.displayName.localeCompare(b.network.displayName);
        if(netSort == 0) {
            return a.name.localeCompare(b.name);
        }
        return netSort;
    });
}

function updateViewCountResult(data) {
   if(chatViewers !== null) {
       while(chatViewers.firstChild) {
           chatViewers.removeChild(chatViewers.firstChild);
       }
       var live_div = document.createElement('div');
       var live_sp = document.createElement('span');

       if(live) {
           live_sp.className = 'live';
           if(!connected) {
               live_sp.innerHTML = 'Disconnected from Multistreamer, reconnecting in ' + seconds + ' seconds';
           }
           else {
               live_sp.innerHTML = 'Live';
           }
           live_div.appendChild(live_sp);
           chatViewers.appendChild(live_div);

           accountList.forEach(function(v) {
               if(v.live === true) {
                   var count = 'unknown';
                   var displayName = v.network.displayName;

                   if (data !== undefined && v.id === data.account_id) {
                     v.viewer_count = data.viewer_count
                   }
                   var el = document.createElement('div');
                   var sp = document.createElement('span');
                   if(v.viewer_count !== null) {
                       count = v.viewer_count;
                   }
                   if(v.http_url !== undefined) {
                     displayName = '<a href="' + v.http_url + '" target="_blank">' + displayName + '</a>';
                   }
                   sp.innerHTML = displayName + ': ' + count;
                   el.appendChild(sp);
                   chatViewers.appendChild(el);
               }
           });
       }
       else {
           live_sp.className = 'offline';
           if(!connected) {
               live_sp.innerHTML = 'Disconnected from Multistreamer, reconnecting in ' + seconds + ' seconds';
           }
           else {
               live_sp.innerHTML = 'Not Streaming';
           }
           live_div.appendChild(live_sp);
           chatViewers.appendChild(live_div);
       }
   }
}

function start_chat(endpoint) {
  ws = new WebSocket(endpoint);
  ws.onopen = function() {
      connected = true;
      updateViewCountResult();
      var msg = {
          type: 'status',
      };
      ws.send(JSON.stringify(msg));
  };

  ws.onclose = function(e) {
      connected = false;
      live = false;
      seconds = 5;
      updateViewCountResult();
      clearInterval(reconnect_func);
      reconnect_func = setInterval(function() {
          seconds--;
          updateViewCountResult();
          if(seconds == 0) {
              clearInterval(reconnect_func);
              start_chat(endpoint);
          }
      },1000);
  };

  ws.onerror = function(e) {
      connected = false;
      live = false;
      seconds = 5;
      updateViewCountResult();
      clearInterval(reconnect_func);
      reconnect_func = setInterval(function() {
          seconds--;
          updateViewCountResult();
          if(seconds == 0) {
              clearInterval(reconnect_func);
              start_chat(endpoint);
          }
      },1000);
  };

  ws.onmessage = function(msg) {
    var data = null;
    try {
      data = JSON.parse(msg.data);
    } catch (e) {
      /* gotta catch em all! */
    }
    if(data === null) {
      return;
    }
    if(data.type === 'text' || data.type === 'emote') {
        appendMessage(data);
    }
    if(data.type === 'viewcountresult') {
        updateViewCountResult(data);
    }
    if(data.type === 'writerresult') {
        if(data.account_id == curAccount.id &&
           data.cur_stream_account_id == tarAccount.id) {
          var inputElement = buildChatBox(curAccount,tarAccount)
          var p = curInput.parentElement;
          p.removeChild(curInput);
          p.appendChild(inputElement);
          curInput = inputElement;
          curInput.focus();
          p.parentElement.firstChild.firstChild.onclick = function() {
              buildChatPickerList(accountList);
          };
        }
    }
    if(data.type == 'status') {
        if(data.status.data_pushing === true) {
            live = true;
            updateAccountList(data.accounts);
            updateViewCountResult();
            if(curInput === undefined || curAccount.id > 0) {
                buildChatInput(null);
            }
        }
        else if(data.status.data_pushing === false) {
            live = false;
            updateAccountList(data.accounts);
            updateViewCountResult();
            if(curInput === undefined || curAccount.id > 0) {
                buildChatInput(null);
            }
        }
    }
  };
};
