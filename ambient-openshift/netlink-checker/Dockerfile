FROM golang:1.20 AS builder

WORKDIR /opt/netlink-checker
COPY main.go ./
COPY go.mod ./
COPY go.sum ./

RUN go get -d ./...
RUN CGO_ENABLED=0 go build

FROM redhat/ubi8:8.6

RUN dnf install -y iproute
COPY --from=builder /opt/netlink-checker/netlink-checker /usr/local/bin

CMD ["/usr/local/bin/netlink-checker"]
