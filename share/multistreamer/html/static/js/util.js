var httpc = {};
/*
 httpc.request = function(self,method,endpoint,params,headers,body)
    local url = api_url .. endpoint
    local req_headers = {
      ['Accept'] = 'application/vnd.twitchtv.v5+json',
    }
    if access_token then
      req_headers['Authorization'] = 'OAuth ' .. access_token
    end
    if headers then
      for k,v in pairs(headers) do
          req_headers[k] = v
      end
    end

    local res, err = _request(self,method,url,params,req_headers,body)
    if err then return false, err end
    ngx_log(ngx_debug,res.body)
    return from_json(res.body)
  end

  httpc.get = function(self,endpoint,params,headers)
    return httpc.request(self,'GET',endpoint,params,headers)
  end
*/

httpc.request = function(method, url, params, headers, body, callback) {
    var xhr = new XMLHttpRequest();
    var p = [];
    Object.keys(params).forEach(function(k) {
        p.push(k + '=' + params[k]);
    });
    url = url + (p.length ? '?' + p.join('&') : '');
    xhr.open(method,url,true);
    xhr.onreadystatechange = function() {
        if(xhr.readyState === 4) {
            callback(xhr.responseText);
        }
    };
    Object.keys(headers).forEach(function(k) {
        xhr.setRequestHeader(k,headers[k]);
    });
    xhr.send(body);
};

httpc.get = function(url, params, headers, body, callback) {
    httpc.request('GET',url,params,headers,body, callback);
};

httpc.getJSON = function(url, params, headers, body, callback) {
    httpc.request('GET',url,params,headers,body,function(data) {
        callback(JSON.parse(data));
    });
};

