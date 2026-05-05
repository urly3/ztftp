small octet stream tftp client

building and running
```
zig build-exe src/ztftp.zig
./ztftp args
```
or
```
zig run src/ztftp.zig -- args
```

where 'args' is the following:  
ip[:port] filename  
  
ip being the ip of the tftp server  
port is optional, defaults to 69.

filename is relative to the current working directory.
