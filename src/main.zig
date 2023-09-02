const std = @import("std");
const constants = @import("./constants.zig");
const contentType = @import("./contentType.zig");
const log = std.log;
const http = std.http;
const net = std.net;
const fs = std.fs;
const ArrayList = std.ArrayList;
const allocator = std.heap.page_allocator;
const Method = http.Method;

pub fn main() void {
    var server = Server.init(constants.IP, constants.PORT) catch |err| {
        log.err("server init err {}", .{err});
        return;
    };
    defer server.deinit();
    while (true) {
        var res = server.croe.accept(.{ .allocator = allocator }) catch |err| {
            log.err("accept err {}", .{err});
            continue;
        };
        res.wait() catch |err| {
            log.err("wait err {}", .{err});
            res.deinit();
            continue;
        };
        var response = Response.init(&res);
        response.route() catch |err| {
            log.err("route err {}", .{err});
            response.toJson("error") catch |e| {
                log.err("toJson err {}", .{e});
                response.deinit();
                continue;
            };
            response.deinit();
            continue;
        };
        defer response.deinit();
    }
}

pub const Server = struct {
    croe: http.Server,

    pub fn init(ip: []const u8, port: u16) !Server {
        var server = http.Server.init(allocator, .{});
        const addr = try net.Address.parseIp(ip, port);
        try server.listen(addr);
        log.info("listen {}", .{addr});
        return .{
            .croe = server,
        };
    }

    pub fn deinit(server: *Server) void {
        server.croe.deinit();
    }
};

const Response = struct {
    heart: *http.Server.Response,
    path: []const u8,
    status: ?[]const u8,
    method: Method,

    pub fn init(res: *http.Server.Response) Response {
        return .{ .heart = res, .path = res.request.target, .status = res.status.phrase(), .method = res.request.method };
    }

    pub fn deinit(res: *Response) void {
        _ = res.heart.reset();
        res.heart.deinit();
        res.* = undefined;
    }

    // 路由
    pub fn route(res: *Response) !void {
        log.info("request => {any} - {s}", .{ res.heart.request.method, res.path });

        // favicon.ico
        if (try res.toIco()) {
            return;
        }

        // static file
        if (try res.toStatic()) {
            return;
        }

        switch (res.method) {
            .GET => {
                try res.getRoute();
            },
            .POST => {
                try res.postRoute();
            },
            else => {
                try res.toHtml("error");
            },
        }
    }

    fn getRoute(res: *Response) !void {
        // 首页
        if (res.match("/")) {
            const html = Utils.readToBytes("templates/index.html", .{});
            if (html != null) {
                defer allocator.free(html.?);
                try res.toHtml(html.?);
                return;
            }
        }

        // 所有帖子页面
        if (res.match("/post")) {
            const html = Utils.readToBytes("templates/postAll.html", .{});
            if (html != null) {
                defer allocator.free(html.?);
                try res.toHtml(html.?);
                return;
            }
        }

        // 关于
        if (res.match("/about")) {
            const html = Utils.readToBytes("templates/about.html", .{});
            if (html != null) {
                defer allocator.free(html.?);
                try res.toHtml(html.?);
                return;
            }
        }

        // 友链
        if (res.match("/friends")) {
            const html = Utils.readToBytes("templates/friends.html", .{});
            if (html != null) {
                defer allocator.free(html.?);
                try res.toHtml(html.?);
                return;
            }
        }

        // 帖子
        if (res.match("/post/*")) {
            const html = Utils.readToBytes("templates/post.html", .{});
            if (html != null) {
                defer allocator.free(html.?);
                try res.toHtml(html.?);
                return;
            }
        }

        try res.toJson("error.");
    }

    fn postRoute(res: *Response) !void {
        // 获取最新的5条
        if (res.match("/getPostTop")) {
            const json = Posts.initTop();
            defer allocator.free(json);
            try res.toJson(json);
            return;
        }

        // 获取所有的
        if (res.match("/getPosts")) {
            const json = Posts.posts();
            defer allocator.free(json);
            try res.toJson(json);
            return;
        }

        // 关于
        if (res.match("/getAbout")) {
            const json = Utils.readToBytes("data/about.md", .{});
            if (json != null) {
                defer allocator.free(json.?);
                try res.toJson(json.?);
                return;
            }
        }

        // 友链
        if (res.match("/getFriends")) {
            const json = Utils.readToBytes("data/friends.md", .{});
            if (json != null) {
                defer allocator.free(json.?);
                try res.toJson(json.?);
                return;
            }
        }

        // 帖子详情
        if (res.match("/getDetails")) {
            const buf = res.getJsonBuf();
            if (buf == null) {
                try res.toJson("error.");
                return;
            }
            defer allocator.free(buf.?);
            const di = try std.json.parseFromSlice(Detail, allocator, buf.?, .{});
            defer di.deinit();
            if (di.value.fileName == null) {
                try res.toJson("error.");
                return;
            }
            const path = try std.mem.concat(allocator, u8, &[_][]const u8{ "data/", di.value.fileName.? });
            defer allocator.free(path);
            const json = Utils.readToBytes(path, .{});
            if (json != null) {
                defer allocator.free(json.?);
                try res.toJson(json.?);
                return;
            }
        }

        try res.toJson("error.");
    }

    pub fn toIco(res: *Response) !bool {
        if (!res.match(constants.ICO)) {
            return false;
        }
        const ct = contentType.get(res.path);
        if (ct == null) {
            return false;
        }
        var bytes = Utils.readToBytes("static/favicon.ico", .{});
        if (bytes == null) {
            return false;
        }
        defer allocator.free(bytes.?);
        try res.response(bytes.?, ct.?);
        return true;
    }

    pub fn toStatic(res: *Response) !bool {
        if (res.path.len <= constants.STATIC_FILE.len) {
            return false;
        }
        if (!Utils.eq(res.path[0..constants.STATIC_FILE.len], constants.STATIC_FILE)) {
            return false;
        }
        const ct = contentType.get(res.path);
        if (ct == null) {
            return false;
        }
        var bytes = Utils.readToBytes(res.path[1..], .{});
        if (bytes == null) {
            return false;
        }
        defer allocator.free(bytes.?);
        try res.response(bytes.?, ct.?);
        return true;
    }

    pub fn toJson(res: *Response, bytes: []const u8) !void {
        try res.response(bytes, "application/json; charset=utf-8");
    }

    pub fn toHtml(res: *Response, bytes: []const u8) !void {
        try res.response(bytes, "text/html; charset=utf-8");
    }

    pub fn response(res: *Response, bytes: []const u8, ct: []const u8) !void {
        res.heart.transfer_encoding = .{ .content_length = bytes.len };
        try res.heart.headers.append("content-type", ct);
        try res.heart.headers.append("connection", "close");
        try res.heart.do();
        try res.heart.writer().writeAll(bytes);
        try res.heart.finish();
    }

    // url 匹配
    fn match(res: *Response, path: []const u8) bool {
        if (path[path.len - 1] == '*') {
            // matchs
            if (Utils.eq(path, "/*")) {
                return true;
            }
            return res.path.len > (path.len - 1) and
                Utils.eq(res.path[0 .. path.len - 1], path[0 .. path.len - 1]);
        }
        return Utils.eq(res.path, path);
    }

    // 获取请求json
    fn getJsonBuf(res: *Response) ?[]const u8 {
        const len = res.heart.request.content_length;
        if (len == null) {
            return null;
        }
        const buf = allocator.alloc(u8, len.?) catch |err| {
            log.err("{}", .{err});
            return null;
        };
        _ = res.heart.readAll(buf) catch |err| {
            log.err("{}", .{err});
            allocator.free(buf);
            return null;
        };
        return buf;
    }
};

pub const Detail = struct {
    fileName: ?[]const u8,
};

pub const Posts = struct {
    pub fn initTop() []const u8 {
        var postJson = Utils.readToBytes("data/index.z", .{});
        if (postJson == null) {
            return "[]";
        }
        defer allocator.free(postJson.?);
        var newJson = ArrayList(u8).init(allocator);
        defer newJson.deinit();
        var count: u4 = 0;
        for (postJson.?) |v| {
            newJson.append(v) catch |e| {
                log.err("posts append err, err info: {}", .{e});
                continue;
            };
            if (v == '\n') {
                count += 1;
                if (count > 5) {
                    break;
                }
            }
        }
        if (newJson.getLast() != ']') {
            newJson.append(']') catch |e| {
                log.err("posts append err, err info: {}", .{e});
            };
        }
        var nj = newJson.toOwnedSlice() catch |e| {
            log.err("toOwnedSlice err, err info: {}", .{e});
            return "[]";
        };
        if (nj[nj.len - 4] == ',') {
            nj[nj.len - 4] = ' ';
        }
        return nj;
    }

    pub fn posts() []const u8 {
        var postJson = Utils.readToBytes("data/index.z", .{});
        if (postJson == null) {
            return "[]";
        }
        return postJson.?;
    }
};

// utils
const Utils = struct {
    fn eq(s1: []const u8, s2: []const u8) bool {
        return std.mem.eql(u8, s1, s2);
    }

    fn readToBytes(path: []const u8, flags: fs.File.OpenFlags) ?[]const u8 {
        var file = fs.cwd().openFile(path, flags) catch |e| {
            log.err("open file error: {}", .{e});
            return null;
        };
        errdefer file.close();
        file.seekTo(0) catch |e| {
            log.err("file seekTo error: {}", .{e});
            return null;
        };
        var buf: [512]u8 = undefined;
        var bufArray = ArrayList(u8).init(allocator);
        errdefer bufArray.deinit();
        while (true) {
            var size = file.read(&buf) catch |e| {
                log.err("read file error: {}", .{e});
                return null;
            };
            if (size == 0) {
                break;
            }
            bufArray.appendSlice(buf[0..size]) catch |e| {
                log.err("appendSlice error: {}", .{e});
                return null;
            };
        }
        var bytes = bufArray.toOwnedSlice() catch |e| {
            log.err("toOwnedSlice error: {}", .{e});
            return null;
        };
        return bytes;
    }
};
